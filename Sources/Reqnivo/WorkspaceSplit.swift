import AppKit
import SwiftUI

struct WorkspaceSplit<First: View, Second: View>: NSViewControllerRepresentable {
    let vertical: Bool
    let autosaveName: String
    let firstMinimum: CGFloat
    let secondMinimum: CGFloat
    let secondCollapsed: Bool?
    let balanceRevision: Int
    let first: First
    let second: Second

    init(vertical: Bool, autosaveName: String, firstMinimum: CGFloat, secondMinimum: CGFloat, secondCollapsed: Bool? = nil,
         balanceRevision: Int = 0,
         @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.vertical = vertical
        self.autosaveName = autosaveName
        self.firstMinimum = firstMinimum
        self.secondMinimum = secondMinimum
        self.secondCollapsed = secondCollapsed
        self.balanceRevision = balanceRevision
        self.first = first()
        self.second = second()
    }

    func makeNSViewController(context: Context) -> WorkspaceSplitController<First, Second> {
        WorkspaceSplitController(first: first, second: second)
    }

    func updateNSViewController(_ controller: WorkspaceSplitController<First, Second>, context: Context) {
        controller.firstHost.rootView = first
        controller.secondHost.rootView = second
        controller.configure(vertical: vertical, autosaveName: autosaveName,
                             firstMinimum: firstMinimum, secondMinimum: secondMinimum, secondCollapsed: secondCollapsed,
                             balanceRevision: balanceRevision)
    }
}

final class WorkspaceSplitController<First: View, Second: View>: NSSplitViewController {
    let firstHost: NSHostingController<First>
    let secondHost: NSHostingController<Second>
    private var balanceRevision: Int?

    init(first: First, second: Second) {
        firstHost = NSHostingController(rootView: first)
        secondHost = NSHostingController(rootView: second)
        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(NSSplitViewItem(viewController: firstHost))
        addSplitViewItem(NSSplitViewItem(viewController: secondHost))
        splitView.dividerStyle = .thin
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(vertical: Bool, autosaveName: String, firstMinimum: CGFloat, secondMinimum: CGFloat, secondCollapsed: Bool? = nil,
                   balanceRevision: Int = 0) {
        let name = NSSplitView.AutosaveName(autosaveName + (vertical ? ".vertical" : ".horizontal"))
        if splitView.isVertical != vertical || splitView.autosaveName != name {
            splitView.autosaveName = nil
            splitView.isVertical = vertical
            splitView.autosaveName = name
        }
        splitViewItems[0].minimumThickness = firstMinimum
        splitViewItems[1].minimumThickness = secondMinimum
        if let secondCollapsed {
            // SwiftUI owns visibility; dragging must not create a conflicting collapse state.
            splitViewItems[1].canCollapse = false
            if splitViewItems[1].isCollapsed != secondCollapsed {
                splitViewItems[1].isCollapsed = secondCollapsed
            }
        }
        let previousBalanceRevision = self.balanceRevision
        self.balanceRevision = balanceRevision
        if let previousBalanceRevision, previousBalanceRevision != balanceRevision {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.balanceRevision == balanceRevision else { return }
                self.view.layoutSubtreeIfNeeded()
                let length = self.splitView.isVertical ? self.splitView.bounds.width : self.splitView.bounds.height
                self.splitView.setPosition((length - self.splitView.dividerThickness) / 2, ofDividerAt: 0)
            }
        }
    }
}
