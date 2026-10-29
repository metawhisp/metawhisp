import AppKit
import Combine
import SwiftUI

/// Two independent interactive surfaces. Neither window covers the gap or the
/// space beside the other surface. Only presented surfaces remain attached.
@MainActor
final class MeetingCoachWindowController: NSObject, NSWindowDelegate {
    enum Surface: Hashable { case capsule, answer }

    private(set) var capsulePanel: NSPanel?
    private(set) var answerPanel: NSPanel?
    private(set) var capsuleShadowPanel: NSPanel?
    private(set) var answerShadowPanel: NSPanel?
    private(set) var answerScrollView: NSScrollView?
    let presentation = MeetingCoachPresentation()
    private let state: MeetingCoachState
    private let ordersWindows: Bool
    /// Twice the shadow radius plus its vertical offset keeps the halo inside its window.
    private let shadowPadding: CGFloat = 70
    private let panelOrdering: (NSPanel) -> any MeetingCoachPanelOrdering
    private let visibleFrame: () -> NSRect
    private let recordingStartedAt: () -> Date?
    private let wave: MeetingCoachWaveModel
    private let onStop: () -> Void
    private let requestQuestionFocus: (NSPanel, MeetingCoachQuestionTextField) -> Void
    struct Transition {
        let revision: Int
        let naturalHeight: CGFloat
        let geometryDuration: TimeInterval
        let opacityDuration: TimeInterval
        let retargets: Bool
        let capsuleFrame: NSRect
        let answerFrame: NSRect
    }
    /// Diagnostic hooks observe the actual staged measurement and joint commit.
    var onTargetMeasured: ((CGFloat) -> Void)?
    var onTargetStaged: (() -> Void)?
    var onTransitionCommitted: ((Transition) -> Void)?
    var onFrameTarget: ((NSPanel, NSRect) -> Void)?
    private(set) var geometryOperationCount = 0
    private(set) var frameOperationCount = 0
    private(set) var frameCommitCount = 0
    private(set) var activeAnimationRevision: Int?
    private(set) var transitionRevision = 0
    private var stagedRevision = 0
    private var transitionTask: Task<Void, Never>?
    private var pendingForce = false
    private var measurementTask: Task<Void, Never>?
    private var installedSnapshot: MeetingCoachRenderSnapshot?
    private var measurementHosting: SelfSizingHostingView<MeetingCoachView>?
    private let reduceMotion: () -> Bool
    private let transitionDiagnostics: MeetingCoachTransitionDiagnostics
    private var stagedInterval: MeetingCoachTransitionDiagnostics.Interval?
    private var animationIntervals: [Int: MeetingCoachTransitionDiagnostics.Interval] = [:]
    private let runAnimation: (TimeInterval, @escaping () -> Void, @escaping () -> Void) -> Void
    private var hostingView: SelfSizingHostingView<MeetingCoachView>?
    private var headerHosting: SelfSizingHostingView<MeetingCoachHeaderView>?
    private var capsuleHosting: SelfSizingHostingView<MeetingCoachCapsuleView>?
    private var cancellables = Set<AnyCancellable>()
    private var inside = Set<Surface>()
    private var collapseTask: Task<Void, Never>?
    private var naturalHeight: CGFloat = 1
    private var isShown = false
    private(set) var isAnswerPresented = false
    private var adjustingFrames = false
    private weak var questionField: MeetingCoachQuestionTextField?
    private var questionFocusPending = false
    private struct ScrollIdentity: Equatable {
        let tab: MeetingCoachState.Tab
        let requestID: UUID?
        let generation: Int?
    }
    private var scrollIdentity: ScrollIdentity?

    var availableAnswerHeight: CGFloat {
        guard let capsulePanel else { return 0 }
        return max(0, capsulePanel.frame.minY - 8 - (visibleFrame().minY + 16))
    }

    init(state: MeetingCoachState? = nil, ordersWindows: Bool = true,
         visibleFrame: @escaping () -> NSRect = { NSScreen.main?.visibleFrame ?? .zero },
         recordingStartedAt: (() -> Date?)? = nil, wave: MeetingCoachWaveModel? = nil,
         onStop: (() -> Void)? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         transitionDiagnostics: MeetingCoachTransitionDiagnostics? = nil,
         runAnimation: @escaping (TimeInterval, @escaping () -> Void, @escaping () -> Void) -> Void = { duration, changes, completion in
             NSAnimationContext.runAnimationGroup { context in
                 context.duration = duration
                 context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                 context.allowsImplicitAnimation = false
                 changes()
             } completionHandler: { Task { @MainActor in completion() } }
         },
         panelOrdering: @escaping (NSPanel) -> any MeetingCoachPanelOrdering = { $0 },
         requestQuestionFocus: @escaping (NSPanel, MeetingCoachQuestionTextField) -> Void = { panel, field in
             panel.makeFirstResponder(field)
         }) {
        self.state = state ?? .shared
        self.ordersWindows = ordersWindows
        self.reduceMotion = reduceMotion
        self.transitionDiagnostics = transitionDiagnostics ?? MeetingCoachTransitionDiagnostics()
        self.runAnimation = runAnimation
        self.panelOrdering = panelOrdering
        self.visibleFrame = visibleFrame
        self.recordingStartedAt = recordingStartedAt ?? { AppDelegate.shared?.meetingRecorder.recordingStartedAt }
        self.wave = wave ?? .shared
        self.onStop = onStop ?? { AppDelegate.shared?.stopMeetingFromCard() }
        self.requestQuestionFocus = requestQuestionFocus
        super.init()
        self.state.onEndQuestionEditing = { [weak self] in self?.giveUpQuestionFocus() }
        self.state.$recordingSurface.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] visible in
                if visible { self?.show() } else { self?.hide() }
            }.store(in: &cancellables)
        self.state.$isQuestionEditing.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] editing in
                guard let self else { return }
                if editing { self.expand() } else { self.scheduleCollapse() }
            }.store(in: &cancellables)
        presentation.$isExpanded.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleTransition() }.store(in: &cancellables)
        self.state.$isAskOpen.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] open in
                guard let self else { return }
                self.questionFocusPending = open
                if open {
                    self.expand()
                    self.focusQuestionIfReady()
                } else { self.scheduleCollapse() }
            }.store(in: &cancellables)
        self.state.renderChanges.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleTransition()
            }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in UserDefaults.standard.bool(forKey: "screenContextEnabled") }
            .removeDuplicates()
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.scheduleTransition() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.scheduleTransition(force: true) }
            .store(in: &cancellables)
    }

    func show() {
        if capsulePanel == nil { createWindows() }
        guard let capsulePanel else { return }
        let interval = !isShown ? transitionDiagnostics.begin(.show) : nil
        if !isShown {
            let screen = visibleFrame()
            let origin = NSPoint(x: screen.midX - capsulePanel.frame.width / 2, y: screen.maxY - 10 - 34)
            if capsulePanel.frame.origin != origin {
                // Native move callbacks must not lay out the previous content
                // between this setup transaction and the measured joint commit.
                let wasAdjusting = adjustingFrames
                adjustingFrames = true
                capsulePanel.setFrameOrigin(origin)
                adjustingFrames = wasAdjusting
                geometryOperationCount += 1
                frameOperationCount += 1
                frameCommitCount += 1
                transitionDiagnostics.committedFrames(interval)
            }
        }
        isShown = true
        if ordersWindows { panelOrdering(capsulePanel).orderFrontRegardless() }
        stageTransition(force: true, animated: false, synchronous: true, interval: interval)
    }

    func hide() {
        let interval = isShown ? transitionDiagnostics.begin(.hide) : nil
        endAnimationIntervals()
        collapseTask?.cancel()
        collapseTask = nil
        inside.removeAll()
        presentation.isExpanded = false
        if state.isQuestionEditing { state.questionEditingEnded(); giveUpQuestionFocus() }
        if ordersWindows {
            if let capsulePanel { panelOrdering(capsulePanel).orderOut(nil) }
            if let answerPanel { panelOrdering(answerPanel).orderOut(nil) }
        }
        isShown = false
        stageTransition(force: true, animated: false, synchronous: true, interval: interval)
    }

    func giveUpQuestionFocus() {
        guard let answerPanel else { return }
        if ordersWindows && isShown && isAnswerPresented && !state.panelHidden {
            MeetingCoachQuestionFocus.giveUp(panel: panelOrdering(answerPanel)) { [weak self] in
                self?.reattachAnswerPanel()
            }
        } else {
            if ordersWindows {
                panelOrdering(answerPanel).endEditing(for: nil)
                panelOrdering(answerPanel).orderOut(nil)
            } else { answerPanel.endEditing(for: nil) }
            reattachAnswerPanel()
        }
    }

    private func focusQuestionIfReady() {
        guard questionFocusPending, state.isAskOpen,
              let answerPanel, let questionField, questionField.window === answerPanel else { return }
        questionFocusPending = false
        requestQuestionFocus(answerPanel, questionField)
    }

    func syncPanelVisibility(force: Bool = false) {
        stageTransition(force: force, animated: false, synchronous: true)
    }

    private func snapshot() -> MeetingCoachRenderSnapshot {
        MeetingCoachRenderSnapshot(state: state, expanded: presentation.isExpanded,
            screenContextEnabled: UserDefaults.standard.bool(forKey: "screenContextEnabled"))
    }

    private func scheduleTransition(force: Bool = false) {
        pendingForce = pendingForce || force
        guard transitionTask == nil else { return }
        transitionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.transitionTask = nil
            let force = self.pendingForce
            self.pendingForce = false
            self.stageTransition(force: force)
        }
    }

    private func stageTransition(force: Bool = false, animated: Bool = true, synchronous: Bool = false,
                                 interval explicitInterval: MeetingCoachTransitionDiagnostics.Interval? = nil) {
        guard hostingView != nil else { transitionDiagnostics.end(explicitInterval); return }
        let target = snapshot()
        // A reverted/equal-layout target still retires an older deferred measurement.
        stagedRevision += 1
        let revision = stagedRevision
        measurementTask?.cancel()
        measurementTask = nil
        transitionDiagnostics.end(stagedInterval)
        stagedInterval = nil
        guard force || target != installedSnapshot else { transitionDiagnostics.end(explicitInterval); return }
        let interval = explicitInterval ?? transitionKind(from: installedSnapshot, to: target).map(transitionDiagnostics.begin)
        stagedInterval = interval
        if !force, let installedSnapshot, target.layout == installedSnapshot.layout,
           isAnswerPresented == (isShown && target.shouldShowPanel) {
            stagedInterval = nil
            commitContent(target, animated: animated, interval: interval)
            return
        }
        let measuring = measurementHosting ?? SelfSizingHostingView(rootView: makeAnswerView(target, measuring: true))
        measurementHosting = measuring
        measuring.permitsKeyboardFocus = false
        var measurementTransaction = Transaction(animation: nil)
        measurementTransaction.disablesAnimations = true
        withTransaction(measurementTransaction) {
            measuring.rootView = makeAnswerView(target, measuring: true)
            measuring.frame = NSRect(x: 0, y: 0, width: 392, height: 600)
            measuring.layoutSubtreeIfNeeded()
        }
        onTargetStaged?()
        guard stagedRevision == revision else { return }
        let finish = { [weak self] in
            guard let self, self.stagedRevision == revision else { return }
            self.measurementTask = nil
            measuring.layoutSubtreeIfNeeded()
            let intrinsic = measuring.intrinsicContentSize
            let height = intrinsic.height.isFinite && intrinsic.height > 0 ? intrinsic.height : measuring.fittingSize.height
            guard height.isFinite, height > 0 else {
                self.transitionDiagnostics.end(interval)
                self.stagedInterval = nil
                return
            }
            let total = ceil(height) + MeetingCoachHeaderView.height
            self.onTargetMeasured?(total)
            guard self.stagedRevision == revision else { return }
            self.stagedInterval = nil
            self.commit(target, natural: total, animated: animated, forceVisibility: force, interval: interval)
        }
        if synchronous { finish() }
        else {
            // Intrinsic-size invalidations finish on this turn before the target is
            // exposed. Even equal-height replacements pass through this commit.
            measurementTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                finish()
            }
        }
    }

    private func transitionKind(from old: MeetingCoachRenderSnapshot?, to target: MeetingCoachRenderSnapshot)
        -> MeetingCoachTransitionDiagnostics.Kind? {
        guard let old else { return nil }
        if old.panelHidden != target.panelHidden { return target.panelHidden ? .hide : .show }
        // Hover collapse also restores Answers; that automatic reset is not a tab click.
        if old.isExpanded && !target.isExpanded && old.selectedTab == .transcript
            && target.selectedTab == .answers && old.isAskOpen == target.isAskOpen { return .hover }
        // User actions precede their side effects: Transcript closes Ask; Ask expands.
        if old.selectedTab != target.selectedTab { return .tab }
        if old.isAskOpen != target.isAskOpen { return .ask }
        if old.isExpanded != target.isExpanded { return .hover }
        if old.requestID != target.requestID || old.generation != target.generation || old.isDraft != target.isDraft
            || old.displayedBlocks != target.displayedBlocks || old.displayedHeard != target.displayedHeard
            || old.displayedQuestion != target.displayedQuestion {
            return target.isDraft ? .delta : .answer
        }
        return nil
    }

    func reattachAnswerPanel() {
        attachPresentedPanels()
        if activeAnimationRevision == nil { updateAnswerHeight(naturalHeight) }
        orderShadowPanels()
    }

    /// The total natural height includes the pinned header; retained for explicit
    /// geometry requests (drag/screen changes and the headless sizing contract).
    func updateAnswerHeight(_ height: CGFloat) {
        guard let target = installedSnapshot, height.isFinite else { return }
        commit(target, natural: height, animated: false, installsContent: false)
    }

    private func commit(_ target: MeetingCoachRenderSnapshot, natural: CGFloat, animated: Bool,
                        installsContent: Bool = true, forceVisibility: Bool = false,
                        interval: MeetingCoachTransitionDiagnostics.Interval? = nil) {
        guard let capsule = capsulePanel, let answer = answerPanel else { transitionDiagnostics.end(interval); return }
        let oldSnapshot = installedSnapshot
        let oldPresented = isAnswerPresented
        let presented = installsContent ? isShown && target.shouldShowPanel : isAnswerPresented
        let current = capsule.frame
        let width = installsContent ? (target.isExpanded ? 208.0 : 168.0) : current.width
        let screen = visibleFrame()
        let x = min(screen.maxX - width, max(screen.minX, current.midX - width / 2))
        let capsuleFrame = NSRect(x: x, y: current.minY, width: width, height: 34)
        let total = max(1, ceil(natural))
        let available = max(0, capsuleFrame.minY - 8 - (screen.minY + 16))
        let capped = min(total, available)
        let answerFrame = NSRect(x: capsuleFrame.midX - 196,
            y: capsuleFrame.minY - 8 - capped, width: 392, height: capped)
        let identity = ScrollIdentity(tab: target.selectedTab,
            requestID: target.selectedTab == .answers ? target.requestID : nil,
            generation: target.selectedTab == .answers ? target.generation : nil)
        let distance = identity == scrollIdentity ? distanceFromScrollTop : 0
        let changedFrames = capsule.frame != capsuleFrame || answer.frame != answerFrame || naturalHeight != total
        guard installsContent || changedFrames || identity != scrollIdentity else { transitionDiagnostics.end(interval); return }
        if !animated { cancelNativeAnimation() }
        scrollIdentity = identity
        naturalHeight = total
        transitionRevision += 1
        let revision = transitionRevision
        let reduced = reduceMotion()
        let duration: TimeInterval = animated && !reduced ? 0.18 : 0
        let retargets = activeAnimationRevision != nil && oldSnapshot?.requestID == target.requestID
            && oldSnapshot?.generation == target.generation && target.isDraft
        if let activeAnimationRevision {
            transitionDiagnostics.end(animationIntervals.removeValue(forKey: activeAnimationRevision))
        }
        if let interval { animationIntervals[revision] = interval }
        activeAnimationRevision = animated ? revision : nil
        isAnswerPresented = presented
        attachPresentedPanels()
        let changes = { [self] in
            let priorFrameOperations = frameOperationCount
            adjustingFrames = true
            defer { adjustingFrames = false }
            // Explicit animator proxies drive visible native frames. Implicit
            // AppKit animation would also move unordered test windows and would
            // animate geometry under Reduce Motion.
            NSAnimationContext.current.allowsImplicitAnimation = false
            if installsContent { installContent(target, animated: animated, reduced: reduced) }
            let capsuleFrameChanged = capsule.frame != capsuleFrame
            let answerFrameChanged = answer.frame != answerFrame
            let answerMoves = answer.frame.origin != answerFrame.origin
            setFrame(capsuleFrame, on: capsule, animated: duration > 0)
            let parentMoves = capsuleFrame.origin != current.origin
            setFrame(answerFrame, on: answer, animated: duration > 0, force: parentMoves)
            let headerHeight = min(MeetingCoachHeaderView.height, capped)
            // On visible native windows the top-pinned header and bottom-pinned
            // scroll viewport follow each intermediate content-bounds change.
            if duration == 0 || !answer.isVisible {
                setViewFrame(NSRect(x: 0, y: capped - headerHeight, width: 392, height: headerHeight), on: headerHosting)
                setViewFrame(NSRect(x: 0, y: 0, width: 392, height: max(0, capped - headerHeight)), on: answerScrollView)
            }
            let scrolls = total > available
            if answerScrollView?.hasVerticalScroller != scrolls {
                answerScrollView?.hasVerticalScroller = scrolls
                geometryOperationCount += 1
            }
            let documentSize = NSSize(width: 392, height: max(1, total - MeetingCoachHeaderView.height))
            if hostingView?.frame.size != documentSize {
                hostingView?.setFrameSize(documentSize)
                geometryOperationCount += 1
                frameOperationCount += 1
            }
            restoreDistanceFromScrollTop(distance)
            if capsuleFrameChanged { capsule.contentView?.updateTrackingAreas() }
            if answerFrameChanged { answer.contentView?.updateTrackingAreas() }
            for (frame, shadow, parentMoved) in [(capsuleFrame, capsuleShadowPanel, parentMoves),
                                                (answerFrame, answerShadowPanel, parentMoves || answerMoves)] {
                guard let shadow else { continue }
                let shadowFrame = frame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
                setFrame(shadowFrame, on: shadow, animated: duration > 0, force: parentMoved)
            }
            if ordersWindows && (oldPresented != presented || forceVisibility) {
                if presented { panelOrdering(answer).orderFrontRegardless() }
                else { panelOrdering(answer).orderOut(nil) }
            }
            orderShadowPanels()
            if frameOperationCount > priorFrameOperations {
                frameCommitCount += 1
                transitionDiagnostics.committedFrames(interval)
            }
            onTransitionCommitted?(Transition(revision: revision, naturalHeight: total,
                geometryDuration: duration, opacityDuration: animated ? 0.18 : 0,
                retargets: retargets, capsuleFrame: capsuleFrame, answerFrame: answerFrame))
        }
        runAnimation(animated ? 0.18 : 0, changes) { [weak self] in
            self?.finishAnimation(revision: revision)
        }
        focusQuestionIfReady()
    }

    private func installContent(_ target: MeetingCoachRenderSnapshot, animated: Bool, reduced: Bool) {
        let applyContent = {
            self.installedSnapshot = target
            self.hostingView?.rootView = self.makeAnswerView(target)
            self.headerHosting?.rootView = MeetingCoachHeaderView(state: self.state, snapshot: target,
                reduceMotionOverride: reduced)
            self.capsuleHosting?.rootView = self.makeCapsuleView(target)
        }
        if animated && !reduced { withAnimation(.easeOut(duration: 0.18), applyContent) }
        else { withTransaction(Transaction(animation: nil), applyContent) }
    }

    /// Header feedback and equal-layout replacements reuse measured geometry. An
    /// in-flight native animation retains its owner and completion revision.
    private func commitContent(_ target: MeetingCoachRenderSnapshot, animated: Bool,
                               interval: MeetingCoachTransitionDiagnostics.Interval?) {
        guard let capsulePanel, let answerPanel else { transitionDiagnostics.end(interval); return }
        transitionRevision += 1
        let revision = transitionRevision
        if let interval { animationIntervals[revision] = interval }
        runAnimation(animated ? 0.18 : 0, { [self] in
            installContent(target, animated: animated, reduced: reduceMotion())
            let identity = ScrollIdentity(tab: target.selectedTab,
                requestID: target.selectedTab == .answers ? target.requestID : nil,
                generation: target.selectedTab == .answers ? target.generation : nil)
            if identity != scrollIdentity {
                scrollIdentity = identity
                restoreDistanceFromScrollTop(0)
            }
            onTransitionCommitted?(Transition(revision: revision, naturalHeight: naturalHeight,
                geometryDuration: 0, opacityDuration: animated ? 0.18 : 0, retargets: false,
                capsuleFrame: capsulePanel.frame, answerFrame: answerPanel.frame))
        }, { [weak self] in self?.finishAnimation(revision: revision) })
        focusQuestionIfReady()
    }

    func finishAnimation(revision: Int) {
        transitionDiagnostics.end(animationIntervals.removeValue(forKey: revision))
        guard activeAnimationRevision == revision else { return }
        activeAnimationRevision = nil
    }

    private func endAnimationIntervals() {
        for interval in animationIntervals.values { transitionDiagnostics.end(interval) }
        animationIntervals.removeAll()
    }

    private func cancelNativeAnimation() {
        guard let activeAnimationRevision else { return }
        transitionDiagnostics.end(animationIntervals.removeValue(forKey: activeAnimationRevision))
        self.activeAnimationRevision = nil
        let wasAdjusting = adjustingFrames
        adjustingFrames = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            for panel in [capsulePanel, answerPanel, capsuleShadowPanel, answerShadowPanel].compactMap({ $0 }) {
                // Freeze the existing target to cancel its animator. This does
                // not request changed geometry and is not a frame commit.
                panel.animator().setFrame(panel.frame, display: false)
            }
        }
        adjustingFrames = wasAdjusting
    }

    private func setFrame(_ frame: NSRect, on panel: NSPanel, animated: Bool, force: Bool = false) {
        guard force || panel.frame != frame else { return }
        geometryOperationCount += 1
        frameOperationCount += 1
        onFrameTarget?(panel, frame)
        if animated && panel.isVisible { panel.animator().setFrame(frame, display: false) }
        else { panel.setFrame(frame, display: false) }
    }

    private func setViewFrame(_ frame: NSRect, on view: NSView?) {
        guard let view, view.frame != frame else { return }
        geometryOperationCount += 1
        frameOperationCount += 1
        view.frame = frame
    }

    private func attachPresentedPanels() {
        guard let capsulePanel, let answerPanel else { return }
        if isAnswerPresented {
            if answerPanel.parent !== capsulePanel { capsulePanel.addChildWindow(answerPanel, ordered: .below) }
            answerPanel.collectionBehavior = MWWindowBehavior.overlay
        } else { answerPanel.parent?.removeChildWindow(answerPanel) }
        for (surface, shadow, visible) in [(capsulePanel, capsuleShadowPanel, isShown),
                                           (answerPanel, answerShadowPanel, isAnswerPresented)] {
            guard let shadow else { continue }
            if visible {
                if shadow.parent !== surface { surface.addChildWindow(shadow, ordered: .below) }
            } else { shadow.parent?.removeChildWindow(shadow) }
        }
    }

    private var distanceFromScrollTop: CGFloat {
        guard let scroll = answerScrollView, let document = scroll.documentView else { return 0 }
        return document.isFlipped ? scroll.documentVisibleRect.minY - document.bounds.minY
            : document.bounds.maxY - scroll.documentVisibleRect.maxY
    }

    private func restoreDistanceFromScrollTop(_ distance: CGFloat) {
        guard let scroll = answerScrollView, let document = scroll.documentView else { return }
        let y = document.isFlipped ? document.bounds.minY + distance
            : document.bounds.maxY - scroll.contentView.bounds.height - distance
        let requested = NSRect(origin: NSPoint(x: 0, y: y), size: scroll.contentView.bounds.size)
        let origin = scroll.contentView.constrainBoundsRect(requested).origin
        guard origin != scroll.contentView.bounds.origin else { return }
        geometryOperationCount += 1
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func pointerEntered(_ surface: Surface) {
        inside.insert(surface)
        expand()
    }

    func pointerExited(_ surface: Surface) {
        inside.remove(surface)
        scheduleCollapse()
    }

    private func expand() {
        collapseTask?.cancel()
        collapseTask = nil
        presentation.isExpanded = true
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        // Initial subscriptions need no delayed reset while already collapsed
        // on Answers; otherwise that timer can undo a subsequent real tab click.
        guard presentation.isExpanded || state.selectedTab != .answers else { return }
        guard inside.isEmpty, !state.isQuestionEditing else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self,
                  self.inside.isEmpty, !self.state.isQuestionEditing else { return }
            self.presentation.isExpanded = false
            self.state.selectTab(.answers)
        }
    }

    func dragEnded() {
        guard let capsulePanel, !adjustingFrames else { return }
        adjustingFrames = true
        defer { adjustingFrames = false }
        let screen = visibleFrame()
        let top = screen.maxY - 10 - 34
        let minimum = screen.minY + 16 + 8 + 160
        var origin = capsulePanel.frame.origin
        origin.y = minimum > top ? top : min(top, max(minimum, origin.y))
        origin.x = min(screen.maxX - capsulePanel.frame.width, max(screen.minX, origin.x))
        if capsulePanel.frame.origin != origin {
            capsulePanel.setFrameOrigin(origin)
            geometryOperationCount += 1
            frameOperationCount += 1
        }
        capsulePanel.contentView?.updateTrackingAreas()
        reattachAnswerPanel()
        answerPanel?.contentView?.updateTrackingAreas()
    }

    func screenChanged() { cancelNativeAnimation(); dragEnded() }
    func windowWillMove(_ notification: Notification) {
        guard !adjustingFrames else { return }
        cancelNativeAnimation()
    }
    func windowDidMove(_ notification: Notification) {
        guard !adjustingFrames, activeAnimationRevision == nil else { return }
        dragEnded()
    }
    func windowDidResize(_ notification: Notification) {
        guard !adjustingFrames, activeAnimationRevision == nil else { return }
        reattachAnswerPanel()
    }
    func windowDidChangeScreen(_ notification: Notification) { screenChanged() }

    private func createWindows() {
        _ = NSApplication.shared
        let capsule = makePanel(surface: .capsule)
        let answer = makePanel(surface: .answer)
        capsulePanel = capsule
        answerPanel = answer
        capsule.delegate = self
        capsule.isMovableByWindowBackground = true
        capsule.setContentSize(NSSize(width: 168, height: 34))
        capsuleShadowPanel = makeShadowPanel(for: capsule, cornerRadius: 17)
        answerShadowPanel = makeShadowPanel(for: answer, cornerRadius: 22)

        let initial = snapshot()
        installedSnapshot = initial
        let capsuleHost = SelfSizingHostingView(rootView: makeCapsuleView(initial))
        capsuleHost.permitsKeyboardFocus = false
        capsuleHost.frame = capsule.contentView?.bounds ?? .zero
        capsuleHost.autoresizingMask = [.width, .height]
        capsule.contentView?.addSubview(capsuleHost)
        capsuleHosting = capsuleHost

        let backdrop = SelfSizingHostingView(rootView: MeetingCoachPanelSurface())
        backdrop.permitsKeyboardFocus = false
        backdrop.sizingOptions = []
        backdrop.frame = answer.contentView?.bounds ?? .zero
        backdrop.autoresizingMask = [.width, .height]
        answer.contentView?.addSubview(backdrop)
        answer.contentView?.wantsLayer = true
        answer.contentView?.layer?.cornerRadius = 22
        answer.contentView?.layer?.masksToBounds = true
        let header = SelfSizingHostingView(rootView: MeetingCoachHeaderView(state: state, snapshot: initial))
        header.permitsKeyboardFocus = false
        header.sizingOptions = []
        header.autoresizingMask = [.width, .minYMargin]
        answer.contentView?.addSubview(header)
        headerHosting = header
        let hosting = SelfSizingHostingView(rootView: makeAnswerView(initial))
        hosting.permitsKeyboardFocus = false
        hosting.frame = NSRect(x: 0, y: 0, width: 392, height: 600)
        let scroll = MeetingCoachScrollView(frame: answer.contentView?.bounds ?? .zero)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.scrollerStyle = .overlay
        scroll.documentView = hosting
        answer.contentView?.addSubview(scroll)
        answerScrollView = scroll
        hostingView = hosting
        hosting.layoutSubtreeIfNeeded()
    }

    private func makeAnswerView(_ target: MeetingCoachRenderSnapshot, measuring: Bool = false) -> MeetingCoachView {
        MeetingCoachView(state: state, presentation: presentation, drawsSurface: false, includesHeader: false,
            reduceMotionOverride: reduceMotion(), snapshot: target,
            onQuestionFieldReady: measuring ? nil : { [weak self] field in
                self?.questionField = field
                self?.focusQuestionIfReady()
            })
    }

    private func makeCapsuleView(_ target: MeetingCoachRenderSnapshot) -> MeetingCoachCapsuleView {
        MeetingCoachCapsuleView(presentation: presentation, state: state, snapshot: target, wave: wave,
            recordingStartedAt: recordingStartedAt,
            onStop: { [weak self] in self?.stopPressed() },
            onHide: { [weak state] in
                guard let state else { return }
                if state.panelHidden { state.showPanel() } else { state.hidePanel() }
            })
    }

    private func stopPressed() {
        guard state.beginStopping() else { return }
        // Flush the native capsule before the existing synchronous stop entry can finalize.
        // Replacing the root exposes the state now rather than waiting for SwiftUI's next turn.
        stageTransition(force: true, animated: false, synchronous: true)
        capsuleHosting?.layoutSubtreeIfNeeded()
        capsulePanel?.contentView?.displayIfNeeded()
        CATransaction.flush()
        onStop()
    }

    private func makeShadowPanel(for surface: NSPanel, cornerRadius: CGFloat) -> NSPanel {
        let frame = surface.frame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
        let shadow = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        shadow.isReleasedWhenClosed = false
        shadow.isOpaque = false
        shadow.backgroundColor = .clear
        shadow.hasShadow = false
        shadow.level = surface.level
        shadow.collectionBehavior = MWWindowBehavior.overlay
        shadow.ignoresMouseEvents = true
        shadow.hidesOnDeactivate = false
        shadow.isMovableByWindowBackground = false
        shadow.contentView = CardShadowView(frame: NSRect(origin: .zero, size: frame.size),
            inset: shadowPadding, cornerRadius: cornerRadius, cutsOutCard: true)
        return shadow
    }

    private func orderShadowPanels() {
        for (shadow, visible) in [(capsuleShadowPanel, isShown), (answerShadowPanel, isAnswerPresented)] {
            guard let shadow else { continue }
            if ordersWindows {
                if visible { panelOrdering(shadow).orderFrontRegardless() }
                else { panelOrdering(shadow).orderOut(nil) }
            }
            shadow.collectionBehavior = MWWindowBehavior.overlay
        }
    }

    private func makePanel(surface: Surface) -> NSPanel {
        let panel = MeetingCoachPanel.make()
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        panel.collectionBehavior = MWWindowBehavior.overlay
        panel.hidesOnDeactivate = false
        let tracking = MeetingCoachTrackingView(frame: panel.contentView?.bounds ?? .zero)
        tracking.onEnter = { [weak self] in self?.pointerEntered(surface) }
        tracking.onExit = { [weak self] in self?.pointerExited(surface) }
        panel.contentView = tracking
        return panel
    }
}
