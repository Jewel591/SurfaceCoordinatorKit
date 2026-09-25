import SurfaceCoordinatorKit
import SwiftUI

extension View {
    /// Hosts app-initiated surfaces for the window this view is the root of.
    ///
    /// Apply once per window, on the root content. The host
    ///
    /// - asks for the permit only while its scene is in the foreground and
    ///   its window is not already presenting something;
    /// - owns the sheet and full-screen cover of every submitted producer
    ///   (macOS renders covers as sheets);
    /// - records `.presented` only after the content reached the window, once
    ///   per permit, and withdraws a presentation that did not land in time;
    /// - releases the permit only after a landed presentation finished
    ///   dismissing, or when its window closes.
    ///
    /// The host never renders `.unobservable` producers; those go through
    /// `SurfaceCoordinator.performUnobservable`.
    ///
    /// - Parameter content: The view for a producer. Called only for
    ///   producers the host submitted.
    @MainActor
    public func surfaceHost<SurfaceContent: View>(
        _ coordinator: SurfaceCoordinator = .shared,
        @ViewBuilder content: @escaping (SurfaceProducerID) -> SurfaceContent
    ) -> some View {
        modifier(SurfaceHostModifier(coordinator: coordinator, surfaceContent: content))
    }
}

private struct SurfaceItem: Identifiable {
    let permit: SurfacePermit
    var id: UInt64 { permit.generation }
}

private struct EvaluationKey: Hashable {
    let revision: UInt64
    let isActive: Bool
}

private struct LandingKey: Hashable {
    let generation: UInt64?
    let isActive: Bool
}

private struct SurfaceHostModifier<SurfaceContent: View>: ViewModifier {
    let coordinator: SurfaceCoordinator
    let surfaceContent: (SurfaceProducerID) -> SurfaceContent

    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID()
    @State private var hostWindow = HostWindowReference()

    /// Generation whose dismissal SwiftUI already started. The binding must
    /// report nil from then on, or SwiftUI presents it again while the
    /// runtime waits for the dismissal to finish.
    @State private var dismissingGeneration: UInt64?

    /// Delay between checks while the window is blocked by something the
    /// runtime cannot observe (a presentation outside the Kit).
    private static var platformBlockedPoll: Duration { .seconds(1) }

    private var ownPermit: SurfacePermit? {
        guard let permit = coordinator.activePermit, permit.scene == sceneID else { return nil }
        return permit
    }

    private var isSceneActive: Bool {
        scenePhase == .active
    }

    func body(content: Content) -> some View {
        content
            .background(HostWindowProbe(reference: hostWindow).frame(width: 0, height: 0))
            .sheet(item: binding(for: sheetStyles)) { item in
                surface(for: item.permit)
            }
            #if !os(macOS)
            .fullScreenCover(item: binding(for: [.fullScreenCover])) { item in
                surface(for: item.permit)
            }
            #endif
            .task(id: EvaluationKey(revision: coordinator.revision, isActive: isSceneActive)) {
                await evaluate()
            }
            .task(id: LandingKey(generation: ownPermit?.generation, isActive: isSceneActive)) {
                await watchLanding()
            }
            .onDisappear {
                // The window closed: release only this window's permit.
                guard let permit = ownPermit else { return }
                if coordinator.isLanded(permit) {
                    coordinator.completeDismissal(permit)
                } else {
                    coordinator.abandon(permit)
                }
            }
    }

    private var sheetStyles: Set<SurfacePresentationStyle> {
        #if os(macOS)
        [.sheet, .fullScreenCover]
        #else
        [.sheet]
        #endif
    }

    private func binding(for styles: Set<SurfacePresentationStyle>) -> Binding<SurfaceItem?> {
        Binding(
            get: {
                guard let permit = ownPermit,
                    styles.contains(permit.producer.style),
                    permit.generation != dismissingGeneration
                else { return nil }
                return SurfaceItem(permit: permit)
            },
            set: { newValue in
                guard newValue == nil, let permit = ownPermit else { return }
                dismissingGeneration = permit.generation
            }
        )
    }

    private func surface(for permit: SurfacePermit) -> some View {
        SurfaceContentContainer(
            content: surfaceContent(permit.producer.id),
            onLanded: { coordinator.confirmPresented(permit) },
            onDisappear: {
                // Guarded by the runtime: only a landed permit completes.
                coordinator.completeDismissal(permit)
            }
        )
    }

    // MARK: - Permit

    private func evaluate() async {
        if let permit = ownPermit {
            // A scene that leaves the foreground before the content landed
            // gives the permit back; it is granted again after returning.
            if !isSceneActive, !coordinator.isLanded(permit) {
                coordinator.abandon(permit)
            }
            return
        }
        dismissingGeneration = nil
        guard isSceneActive else { return }

        while !Task.isCancelled {
            guard hostWindow.isReadyForPresentation else {
                try? await Task.sleep(for: Self.platformBlockedPoll)
                continue
            }
            switch coordinator.requestPermit(scene: sceneID) {
            case .granted:
                return
            case .retry(let delay):
                try? await Task.sleep(for: .seconds(max(delay, 0.05)))
            case .unavailable:
                return
            }
        }
    }

    private func watchLanding() async {
        guard let permit = ownPermit, isSceneActive, !coordinator.isLanded(permit) else { return }
        try? await Task.sleep(for: .seconds(coordinator.landingPolicy.landingTimeout))
        guard !Task.isCancelled, coordinator.isCurrent(permit), !coordinator.isLanded(permit)
        else { return }
        coordinator.reportNotLanded(permit, detail: hostWindow.presentedChainDescription)
    }
}

/// Wraps surface content with a zero-size probe. SwiftUI calls `onAppear`
/// even when the platform refused the presentation, so landing only counts
/// once the probe entered a window.
private struct SurfaceContentContainer<Content: View>: View {
    let content: Content
    let onLanded: () -> Void
    let onDisappear: () -> Void

    var body: some View {
        ZStack {
            LandingProbe(onLanded: onLanded)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            content
        }
        .onDisappear(perform: onDisappear)
    }
}

// MARK: - Platform probes

#if canImport(UIKit)
import UIKit

@MainActor
private final class HostWindowReference {
    weak var view: UIView?

    /// The host window's scene is foreground-active and its root presents
    /// nothing, so a new sheet or cover can attach.
    var isReadyForPresentation: Bool {
        guard let window = view?.window, let scene = window.windowScene else { return false }
        return scene.activationState == .foregroundActive
            && window.rootViewController?.presentedViewController == nil
    }

    /// Controller types presented on the host window, bottom-up.
    var presentedChainDescription: String {
        var chain: [String] = []
        var controller = view?.window?.rootViewController?.presentedViewController
        while let current = controller {
            chain.append(String(describing: type(of: current)))
            controller = current.presentedViewController
        }
        return chain.isEmpty ? "none" : chain.joined(separator: " > ")
    }
}

private struct HostWindowProbe: UIViewRepresentable {
    let reference: HostWindowReference

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        reference.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        reference.view = view
    }
}

private struct LandingProbe: UIViewRepresentable {
    let onLanded: () -> Void

    func makeUIView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onLanded = onLanded
    }

    final class ProbeView: UIView {
        var onLanded: () -> Void = {}

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // Window attachment happens inside the presentation transaction;
            // defer state changes by one turn.
            DispatchQueue.main.async { [weak self] in self?.onLanded() }
        }
    }
}
#elseif canImport(AppKit)
import AppKit

@MainActor
private final class HostWindowReference {
    weak var view: NSView?

    var isReadyForPresentation: Bool {
        guard let window = view?.window else { return false }
        return window.isVisible && window.attachedSheet == nil
    }

    var presentedChainDescription: String {
        var chain: [String] = []
        var sheet = view?.window?.attachedSheet
        while let current = sheet {
            chain.append(String(describing: type(of: current.contentViewController ?? NSViewController())))
            sheet = current.attachedSheet
        }
        return chain.isEmpty ? "none" : chain.joined(separator: " > ")
    }
}

private struct HostWindowProbe: NSViewRepresentable {
    let reference: HostWindowReference

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        reference.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        reference.view = view
    }
}

private struct LandingProbe: NSViewRepresentable {
    let onLanded: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onLanded = onLanded
    }

    final class ProbeView: NSView {
        var onLanded: () -> Void = {}

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.onLanded() }
        }
    }
}
#endif
