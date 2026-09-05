import SwiftUI

/// Removes the outgoing native back button before it overlaps the home heading.
/// NavigationStack still owns navigation and the interactive pop gesture.
struct RootReturnButtonBehavior: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Observer {
        Observer()
    }

    func updateUIViewController(_ uiViewController: Observer, context: Context) {}

    final class Observer: UIViewController {
        private weak var hiddenItem: UINavigationItem?
        private var wasHidden = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard let navigationController,
                  let transition = transitionCoordinator,
                  let from = transition.viewController(forKey: .from),
                  let to = transition.viewController(forKey: .to),
                  to === navigationController.viewControllers.first,
                  from !== to else { return }

            var ancestor = parent
            while let current = ancestor, current !== from {
                ancestor = current.parent
            }
            guard ancestor === from else { return }

            let item = from.navigationItem
            hiddenItem = item
            wasHidden = item.hidesBackButton
            UIView.performWithoutAnimation {
                item.setHidesBackButton(true, animated: false)
                navigationController.navigationBar.layoutIfNeeded()
            }
            transition.animate(alongsideTransition: nil) { [weak self] _ in
                self?.restoreButton()
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            restoreButton()
        }

        private func restoreButton() {
            hiddenItem?.setHidesBackButton(wasHidden, animated: false)
            hiddenItem = nil
        }
    }
}
