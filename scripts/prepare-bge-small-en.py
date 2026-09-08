#!/usr/bin/env python3
"""Developer-only pinned BGE -> Core ML conversion. Never reads user PDFs.

Run in an isolated venv with torch==2.5.0 transformers==4.51.3
coremltools==8.3.0 numpy==1.26.4. Output is deliberately outside app sources.
"""
import argparse
import hashlib
import json
import shutil
import time
from pathlib import Path
from urllib.request import urlopen

import coremltools as ct
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

MODEL = "BAAI/bge-small-en-v1.5"
REVISION = "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
WEIGHT_SHA = "3c9f31665447c8911517620762200d2245a2518d6e7208acc78cd9db317e21ad"
PREFIX = "Represent this sentence for searching relevant passages: "


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--package-name", default="SmallEN")
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    source = root / "source"
    source.mkdir(exist_ok=True)
    for name in ["config.json", "model.safetensors", "tokenizer.json",
                 "tokenizer_config.json", "special_tokens_map.json", "vocab.txt", "README.md"]:
        target = source / name
        if not target.exists():
            print(f"Downloading {name}", flush=True)
            with urlopen(f"https://huggingface.co/{MODEL}/resolve/{REVISION}/{name}", timeout=90) as response:
                with target.with_suffix(target.suffix + ".partial").open("wb") as output:
                    shutil.copyfileobj(response, output)
            target.with_suffix(target.suffix + ".partial").rename(target)
    if sha(source / "model.safetensors") != WEIGHT_SHA:
        raise RuntimeError("Official weight SHA-256 mismatch")
    tokenizer = AutoTokenizer.from_pretrained(source, local_files_only=True)
    model = AutoModel.from_pretrained(source, local_files_only=True, use_safetensors=True,
                                     attn_implementation="eager").eval()

    class Encoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.encoder = model

        def forward(self, input_ids, attention_mask):
            # Avoid casting torch.finfo(float32).min to fp16 -inf in the
            # generic HF mask path (0 * -inf produces NaN after conversion).
            hidden = self.encoder.embeddings(input_ids=input_ids)
            mask = (1.0 - attention_mask[:, None, None, :].float()) * -10000.0
            values = self.encoder.encoder(hidden, attention_mask=mask, return_dict=False)[0][:, 0, :]
            return torch.nn.functional.normalize(values, p=2, dim=1)

    wrapper = Encoder().eval()
    example = tokenizer("A document retrieval example.", return_tensors="pt")
    traced = torch.jit.trace(wrapper, (example["input_ids"], example["attention_mask"]))
    length = ct.RangeDim(lower_bound=2, upper_bound=512, default=128)
    converted = ct.convert(
        traced, inputs=[ct.TensorType(name="input_ids", shape=(1, length), dtype=np.int32),
                        ct.TensorType(name="attention_mask", shape=(1, length), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    package = root / args.package_name
    if package.exists():
        raise RuntimeError("Output SmallEN already exists; choose a fresh output directory")
    package.mkdir()
    converted.save(str(root / "embedding.mlpackage"))
    compiled = ct.models.utils.compile_model(str(root / "embedding.mlpackage"))
    shutil.copytree(compiled, package / "embedding.mlmodelc")
    shutil.copy2(source / "vocab.txt", package / "vocab.txt")
    # Upstream model card declares MIT; retain upstream metadata with the artifact.
    shutil.copy2(source / "README.md", package / "UPSTREAM-README.md")
    shutil.copy2(Path(__file__).parent / "model-assets/BGE-MIT-LICENSE.txt", package / "LICENSE.txt")
    samples = ["Neural networks recognize handwritten characters.",
               PREFIX + "Which architecture recognizes handwriting?",
               "  Café naïve résumé — co-operate!  ", "BERT's input_ids = [CLS] tokens.",
               "Tabs\tnewlines\ntext\u0000cleaning.", "中文用于分词一致性检查。",
               "[MASK] [SEP] [UNK] [PAD]", "a" * 101,
               "A long sentence about neural networks and image classification. " * 40]
    fixtures = []
    for text in samples:
        tokens = tokenizer(text, return_tensors="pt", truncation=True, max_length=512)
        with torch.no_grad():
            expected = torch.nn.functional.normalize(model(**tokens).last_hidden_state[:, 0, :], p=2, dim=1)[0].numpy()
        inputs = {key: tokens[key].numpy().astype(np.int32) for key in ["input_ids", "attention_mask"]}
        start = time.perf_counter()
        actual = converted.predict(inputs)["embedding"].reshape(-1)
        duration = time.perf_counter() - start
        cosine = float(np.dot(expected, actual) / (np.linalg.norm(expected) * np.linalg.norm(actual)))
        if not np.isfinite(expected).all() or not np.isfinite(actual).all() or not np.isfinite(cosine) or cosine < 0.999:
            raise RuntimeError(f"Core ML parity failed: {cosine}")
        fixtures.append(dict(text=text, ids=tokens["input_ids"][0].tolist(),
                             embedding=expected.tolist(), cosine=cosine, seconds=duration))
    (package / "parity.json").write_text(json.dumps(fixtures, ensure_ascii=False, allow_nan=False))
    files = {str(path.relative_to(package)): sha(path) for path in sorted(package.rglob("*")) if path.is_file()}
    manifest = dict(schema=1, model=MODEL, revision=REVISION, dimensions=384,
                    maximumTokens=512, tokenizer="bert-uncased-wordpiece-v1",
                    pooling="cls-l2", precision="float16", queryPrefix=PREFIX, files=files)
    (package / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True))
    print(json.dumps(dict(package=str(package), bytes=sum(p.stat().st_size for p in package.rglob("*") if p.is_file()),
                          parity=[dict(cosine=f["cosine"], seconds=f["seconds"]) for f in fixtures]), indent=2), flush=True)


if __name__ == "__main__":
    main()
