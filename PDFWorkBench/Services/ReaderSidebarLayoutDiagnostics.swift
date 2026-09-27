import Foundation

@MainActor
enum ReaderSidebarLayoutDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let visible: Set<ReaderSidebarSection> = [.fullText, .dogears, .annotations]
        func layout(_ count: Int, height: CGFloat = 700,
            expanded: Set<ReaderSidebarSection>? = nil) -> ReaderSidebarLayout {
            ReaderSidebarLayout(availableHeight: height, expandedSections: expanded ?? [.dogears, .annotations],
                visibleSections: visible, dogearCount: count)
        }
        let one = layout(1)
        let five = layout(5)
        let eight = layout(8)
        let many = layout(500)
        check(one.height(for: .dogears) == 82 && one.height(for: .annotations) == 582,
            "A one-item Dog-ear index still consumes an equal share of the sidebar.")
        check(five.height(for: .dogears) == 218,
            "Five Dog-ear rows cannot be shown completely with their row spacing and content padding.")
        check(eight.height(for: .dogears) == 320 && many.height(for: .dogears) == eight.height(for: .dogears),
            "A long Dog-ear index did not stop growing at its eight-row scroll limit.")
        check(many.height(for: .annotations) == 344,
            "A long Dog-ear index consumed the annotation pane's useful reading area.")
        check(layout(5, height: 400).height(for: .annotations) == 240
            && layout(5, height: 400).height(for: .dogears) == 124,
            "A short window did not make the Dog-ear list scroll before shrinking annotations below their minimum.")
        check(layout(1, height: 358).fitsExpandedSections && !layout(1, height: 357).fitsExpandedSections,
            "Expansion capacity still assumes that a compact Dog-ear index requires 240 points.")
        check(layout(0).height(for: .dogears) == 96 && layout(-1).height(for: .dogears) == 96,
            "The empty Dog-ear hint has no bounded content height.")
        check(layout(1, expanded: [.dogears]).height(for: .dogears) == 82,
            "A lone expanded Dog-ear section stretches into unused sidebar space.")
        let collapsed = layout(500, expanded: [.annotations])
        check(collapsed.height(for: .dogears) == 36 && collapsed.height(for: .annotations) == 628,
            "Collapsed Dog-ears still reserve row height or prevent annotations from filling the sidebar.")
        check(collapsed.height(for: .askSelection) == 0,
            "The detached Ask section reserved sidebar space.")
        let layouts = [one, five, eight, many, layout(0), layout(5, height: 400)]
        check(layouts.allSatisfy { item in
            abs(visible.reduce(CGFloat(0)) { $0 + item.height(for: $1) } - item.availableHeight) < 0.01
        }, "Expanded annotation layouts overlap or leave an unallocated gap after sizing Dog-ears.")
        let legacy = ReaderSidebarLayout(availableHeight: 800,
            expandedSections: [.dogears, .annotations, .askSelection], dogearCount: 8)
        check(legacy.height(for: .annotations) >= 240 && legacy.height(for: .askSelection) >= 240
            && ReaderSidebarSection.allCases.reduce(CGFloat(0)) { $0 + legacy.height(for: $1) } == 800,
            "The legacy Ask pane is starved when Dog-ears grow.")
        return (checks, failures)
    }
}
