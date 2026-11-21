import StandByKit
import SwiftUI
import UIKit

/// The first run, V2 (docs/design/onboarding, 16 November 2026).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var flow: OnboardingCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var artworkNamespace
    /// The cover flies from the Mac picture to the Lock Screen picture; with
    /// Reduce Motion the screens only crossfade.
    private var artworkSpace: Namespace.ID? { reduceMotion ? nil : artworkNamespace }

    var body: some View {
        let facts = flow.facts(for: model)
        ZStack {
            switch flow.route {
            case .welcome?: WelcomeScene(flow: flow).transition(.opacity)
            case .macApp?: MacAppScene(flow: flow).transition(.opacity)
            case .pair?: PairScene(flow: flow).transition(.opacity)
            case .play?: PlayScene(flow: flow, artworkSpace: artworkSpace).transition(.opacity)
            case .success?: SuccessScene(flow: flow, artworkSpace: artworkSpace).transition(.opacity)
            case .continueIntro?: ContinueIntroScene(flow: flow).transition(.opacity)
            case .continueMusic?: ContinueMusicScene(flow: flow).transition(.opacity)
            case .continueAccess?: ContinueAccessScene(flow: flow).transition(.opacity)
            case .continueReady?: ContinueReadyScene(flow: flow).transition(.opacity)
            case nil: EmptyView()
            }
        }
        .onChange(of: facts, initial: true) { _, new in flow.update(new) }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings with Apple Music allowed: carry on.
            if phase == .active { Task { await flow.checkAppleMusic() } }
        }
        .sheet(isPresented: $flow.showingHelp) { SetupHelp(flow: flow) }
    }
}

// MARK: - Shared pieces

private let setupSteps = ["Mac", "Pair", "Play"]
private let continueSteps = ["Music", "Access"]

/// Back, the step and its name, and Help or Not Now; the scrolling body;
/// and the actions, kept at the bottom.
private struct SetupScaffold<Content: View, Actions: View>: View {
    enum Trailing { case help, notNow(() -> Void), none }
    let flow: OnboardingCoordinator
    var showsBack = true
    var trailing: Trailing = .help
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    if showsBack {
                        Button { flow.back() } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
                            .accessibilityLabel("Back")
                            .accessibilityShowsLargeContentViewer()
                    }
                    Spacer()
                    switch trailing {
                    case .help:
                        Button { flow.showingHelp = true } label: { Image(systemName: "questionmark.circle").font(.title3).frame(width: 44, height: 44) }
                            .accessibilityLabel("Setup Help")
                            .accessibilityShowsLargeContentViewer()
                    case .notNow(let action):
                        Button("Not Now", action: action).padding(.horizontal, 8).frame(height: 44)
                            .accessibilityShowsLargeContentViewer()
                    case .none:
                        EmptyView()
                    }
                }
                if let route = flow.route, let step = Onboarding.setupStep(of: route) {
                    SetupProgress(step: step.index, of: step.of, names: step.of == 3 ? setupSteps : continueSteps)
                }
            }
            // Like a navigation bar: it stops growing, and a long press shows
            // the large content viewer.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 8)
            ActionsLayout { content } actions: { actions }
        }
    }
}

/// A scrolling body with its actions under it. The actions stay at the
/// bottom, except at accessibility text sizes, where pinned buttons would take
/// half the screen: there they follow the words and scroll with them.
private struct ActionsLayout<Content: View, Actions: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var spacing: CGFloat = 16
    var horizontalPadding: CGFloat = 24
    var topPadding: CGFloat = 8
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        let inline = typeSize.isAccessibilitySize
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    content
                    if inline { VStack(spacing: 4) { actions }.padding(.top, 8) }
                }
                .padding(.horizontal, horizontalPadding).padding(.top, topPadding).padding(.bottom, 24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            if !inline {
                VStack(spacing: 4) { actions }
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .frame(maxWidth: 560)
            }
        }
    }
}

/// The steps, named, so people can see the whole way (comparison, correction 1).
private struct SetupProgress: View {
    let step: Int
    let of: Int
    let names: [String]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<of, id: \.self) { i in
                VStack(spacing: 4) {
                    Capsule().fill(i + 1 < step ? Color.primary : i + 1 == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 36, height: 4)
                    Text(names[i]).font(.caption2.weight(i + 1 == step ? .semibold : .regular))
                        .foregroundStyle(i + 1 == step ? .primary : .secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step) of \(of): \(names[step - 1])")
    }
}

private struct DeviceLabel: View {
    let onMac: Bool
    let text: String
    var body: some View {
        Label(text, systemImage: onMac ? "laptopcomputer" : "iphone")
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, 6)
    }
}

private struct Headline: View {
    let text: String
    var body: some View { Text(text).font(.title.bold()).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader) }
}

private struct Explanation: View {
    let text: LocalizedStringKey
    var body: some View { Text(text).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private struct StatusLine: View {
    var done = false
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } else { ProgressView() }
            Text(text).foregroundStyle(done ? Color.green : .secondary)
        }
        .font(.subheadline)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct Note: View {
    let title: String
    let text: String
    var problem = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(problem ? Color.red : .primary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.subheadline.weight(.semibold)).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(problem ? Color.red.opacity(0.1) : Color.secondary.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
    }
}

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule)
    }
}

private struct SecondaryButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.borderless).controlSize(.large).padding(.vertical, 8)
    }
}

private let macAppURL = URL(string: "https://madewithmerritt.com/second-chair/")!

private extension AppModel {
    var artworkImage: Image? { artwork.map { Image(decorative: $0, scale: 1) } }
}

// MARK: - Introduction

private struct WelcomeScene: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let flow: OnboardingCoordinator
    @State private var index = 0
    @State private var elapsed: TimeInterval = 112

    private var record: DemoRecord { DemoRecord.welcome[index % DemoRecord.welcome.count] }

    var body: some View {
        ActionsLayout(spacing: 24, horizontalPadding: 20, topPadding: 16) {
            NowPlayingPicture(artwork: record.cover, title: record.title, artist: record.artist, source: "MacBook Pro",
                              wall: record.wall, elapsed: elapsed, duration: record.duration)
                .id(record.id)
                .transition(.opacity)
            VStack(alignment: .leading, spacing: 12) {
                Text("Your Mac’s music.\nOn your iPhone.").font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Play, pause and skip from your Lock Screen and StandBy. When you head out, take it with you: same song, same place, same queue.")
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            PrimaryButton("Get Started") { flow.getStarted(model) }
            SecondaryButton("Explore the Demo") { flow.exploreDemo(model) }
            Text("Requires Second Chair for Mac, a free download.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .background(alignment: .top) {
            LinearGradient(colors: [record.wall.top.opacity(0.32), .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea().animation(.smooth(duration: 0.8), value: index)
        }
        .task {
            // The records change, so it reads as music, not a diagram. Still with Reduce Motion.
            guard !reduceMotion else { return }
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                elapsed += 1
                if tick % 7 == 0 {
                    withAnimation(.smooth(duration: 0.8)) {
                        index += 1
                        elapsed = Double(40 + (index * 37) % 90)
                    }
                }
            }
        }
    }
}

// MARK: - Connection

private struct MacAppScene: View {
    let flow: OnboardingCoordinator

    var body: some View {
        SetupScaffold(flow: flow) {
            MacPicture(part: .menuBar)
            DeviceLabel(onMac: true, text: "On your Mac")
            Headline(text: "First, your Mac.")
            Explanation(text: "Second Chair for Mac sends your music here. It’s free, and lives in the menu bar as ♪.")
            if flow.linkSent {
                StatusLine(done: true, text: "Open the link on your Mac and install Second Chair, then come back.")
            }
        } actions: {
            if flow.linkSent {
                PrimaryButton("Continue") { flow.go(.pair) }
                ShareLink(item: macAppURL, subject: Text("Second Chair for Mac"), message: Text("Second Chair for Mac, free.")) {
                    Text("Send Again").multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless).controlSize(.large).padding(.vertical, 8)
            } else {
                ShareLink(item: macAppURL, subject: Text("Second Chair for Mac"), message: Text("Second Chair for Mac, free.")) {
                    Text("Send Link to Mac").multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule)
                .simultaneousGesture(TapGesture().onEnded { flow.linkSent = true })
                SecondaryButton("It’s Already on My Mac") { flow.go(.pair) }
            }
        }
    }
}

private struct PairScene: View {
    @Environment(AppModel.self) private var model
    @Bindable var flow: OnboardingCoordinator

    var body: some View {
        let awaiting = flow.facts(for: model).awaitingMacName
        switch flow.pairingProblem {
        case .denied(let mac)?:
            outcome(title: "\(mac) didn’t allow this iPhone.", text: "If that wasn’t meant to happen, get a new code and click Allow this time.", button: "Try Again")
        case .expired?:
            outcome(title: "That took too long.", text: "The request expired after five minutes. Get a new code on your Mac and try again.", button: "Get a New Code")
        default:
            if let awaiting { approve(awaiting) } else { entry }
        }
    }

    private var entry: some View {
        SetupScaffold(flow: flow) {
            MacPicture(part: flow.code.isEmpty ? .pairButton : .pairingCode)
            DeviceLabel(onMac: true, text: "On your Mac, then here")
            Headline(text: "Connect your iPhone.")
            Explanation(text: "On your Mac, click ♪ in the menu bar, then **\(MacMenuText.pairIPhone)** Type the six-digit code here.")
            CodeField(code: $flow.code, invalid: problemText != nil, disabled: flow.isPairing, paused: flow.showingHelp) { flow.submitCode(model) }
                .padding(.top, 4)
            if let problemText {
                Text(problemText).font(.subheadline).foregroundStyle(.red).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isStaticText)
            } else if flow.isPairing {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                HStack(spacing: 4) {
                    Text("No Mac nearby?").foregroundStyle(.secondary)
                    Button("Explore the demo") { flow.exploreDemo(model) }
                }
                .font(.subheadline).frame(maxWidth: .infinity)
            }
        } actions: {
            EmptyView()
        }
    }

    private var problemText: String? {
        switch flow.pairingProblem {
        case .wrongCode?: "That code didn’t work. Check the code on your Mac, or choose \(MacMenuText.pairIPhone) again for a new one."
        case .offline?: "This iPhone isn’t online. Check Wi-Fi or mobile data, then try again."
        case .tooManyTries?: "Too many tries. Wait a minute, then try again."
        case .other(let message)?: message
        default: nil
        }
    }

    private func approve(_ mac: String) -> some View {
        SetupScaffold(flow: flow) {
            MacPicture(part: .allow)
            DeviceLabel(onMac: true, text: "On your Mac")
            Headline(text: "One last click on your Mac.")
            Explanation(text: "Click **\(MacMenuText.allow)** in the ♪ menu on \(mac).")
            StatusLine(text: "Waiting for \(mac)…")
        } actions: {
            Button { flow.cancelPairing() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).controlSize(.large).buttonBorderShape(.capsule)
        }
    }

    private func outcome(title: String, text: String, button: String) -> some View {
        SetupScaffold(flow: flow) {
            MacPicture(part: .allow)
            DeviceLabel(onMac: true, text: "On your Mac")
            Headline(text: title)
            Explanation(text: LocalizedStringKey(text))
        } actions: {
            PrimaryButton(button) { flow.tryPairingAgain() }
        }
    }
}

/// Six boxes over an invisible text field, so the number pad, paste and
/// VoiceOver all work as for any field.
private struct CodeField: View {
    @Binding var code: String
    var invalid: Bool
    var disabled: Bool
    /// True while something covers the field, such as the help sheet: the
    /// number pad steps aside and comes back after.
    var paused = false
    var onComplete: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .disabled(disabled)
                .foregroundStyle(.clear).tint(.clear)
                .accessibilityLabel("Six-digit pairing code")
                .onChange(of: code) { _, new in
                    let clean = String(new.filter(\.isNumber).prefix(6))
                    if clean != new { code = clean }
                    if clean.count == 6 { onComplete() }
                }
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    if i == 3 { Color.clear.frame(width: 4) }
                    box(i)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture { focused = true }
        .onAppear { focused = !paused }
        .onChange(of: paused) { _, now in focused = !now }
    }

    private func box(_ i: Int) -> some View {
        let digits = Array(code)
        let current = i == digits.count && focused
        return Text(i < digits.count ? String(digits[i]) : "")
            .font(.title.weight(.semibold).monospacedDigit())
            .frame(width: 44, height: 56)
            .background(Color.secondary.opacity(0.14), in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(invalid ? Color.red : current ? Color.accentColor : .clear, lineWidth: 2))
    }
}

private struct PlayScene: View {
    @Environment(AppModel.self) private var model
    let flow: OnboardingCoordinator
    let artworkSpace: Namespace.ID?

    /// "Connected" while the Mac is reachable; only "paired" while it's
    /// offline, so the line above the offline note doesn't contradict it.
    private func connectedLine(mac: String, offline: Bool) -> String {
        switch (flow.resumed, offline) {
        case (false, false): "Connected to \(mac)"
        case (false, true): "Paired with \(mac)"
        case (true, false): "Welcome back. You’re connected."
        case (true, true): "Welcome back. You’re paired."
        }
    }

    var body: some View {
        let mac = flow.macName(model)
        let offline = flow.isMacOffline(model)
        let playing = model.macIsPlaying
        SetupScaffold(flow: flow, showsBack: false, trailing: .notNow { flow.finish() }) {
            Label(connectedLine(mac: mac, offline: offline), systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.multicolor)
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
            MacPicture(part: .play(title: model.macTrack?.title, artist: model.macTrack?.artist, playing: playing),
                       artwork: model.artworkImage, artworkNamespace: artworkSpace)
            DeviceLabel(onMac: true, text: "On your Mac")
            Headline(text: "Play something in Music.")
            Explanation(text: "Any song. It’ll appear on this iPhone, and on your Lock Screen.")
            if offline {
                Note(title: "\(mac) is offline.", text: "Wake it, and check it’s connected to the internet. This screen carries on when it’s back.", problem: true)
            } else if flow.playerBlocked {
                Note(title: "Another app is using the Lock Screen player.", text: "Tap Show on Lock Screen to show your Mac’s music instead.")
            } else {
                StatusLine(text: playing ? "Here it comes…" : "Waiting for music on \(mac)…")
                if flow.waitedLong {
                    Note(title: "Still nothing?", text: "Check that Music is playing on \(mac), and that ♪ is in its menu bar.",
                         actionTitle: "Check Again") { Task { await model.reconnect() } }
                }
            }
        } actions: {
            if flow.playerBlocked {
                PrimaryButton("Show on Lock Screen") { Task { await flow.showOnLockScreen(model) } }
            }
        }
        .task {
            // Someone back from Home may have stopped showing earlier: this step means showing.
            if !model.isNowPlayingEnabled { await model.activateNowPlaying() }
            while !Task.isCancelled {
                flow.checkPlayer(model.sessionController)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(45))
            flow.markWaitedLong()
        }
    }
}

// MARK: - Success

private struct SuccessScene: View {
    @Environment(AppModel.self) private var model
    let flow: OnboardingCoordinator
    let artworkSpace: Namespace.ID?

    var body: some View {
        let track = model.attributes?.track
        let title = track?.title ?? model.macTrack?.title ?? "Your music"
        let wall = ArtworkColours.wall(for: model.artwork)
        ActionsLayout(spacing: 24, horizontalPadding: 20, topPadding: 16) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                NowPlayingPicture(artwork: model.artworkImage ?? Image(systemName: "music.note"),
                                  title: title, artist: track?.artist ?? model.macTrack?.artist ?? "",
                                  source: flow.macName(model), wall: wall,
                                  elapsed: model.attributes?.elapsed(at: context.date) ?? 0,
                                  duration: track?.duration ?? model.macTrack?.duration ?? 1,
                                  artworkNamespace: artworkSpace)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("\(title) is on your Lock Screen.").font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Lock your iPhone to see it. Stand it on a charger, on its side, for StandBy.")
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            PrimaryButton("Continue") { flow.go(.continueIntro) }
        }
        .background(alignment: .top) {
            LinearGradient(colors: [wall.top.opacity(0.32), .clear], startPoint: .top, endPoint: .center).ignoresSafeArea()
        }
        .sensoryFeedback(.success, trigger: flow.route)
    }
}

// MARK: - Continue Listening

private struct SongSeats: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var startOnPhone = false
    var moves = false
    @State private var onPhone = false

    var body: some View {
        SeatsPicture(artwork: model.artworkImage ?? DemoRecord.welcome[0].cover,
                     wall: model.artwork == nil ? DemoRecord.welcome[0].wall : ArtworkColours.wall(for: model.artwork),
                     onPhone: onPhone, elapsed: model.attributes?.elapsed(at: Date()) ?? 112)
            .onAppear {
                onPhone = startOnPhone
                guard moves else { return }
                if reduceMotion { onPhone = true; return }
                withAnimation(.smooth(duration: 1.3).delay(0.9)) { onPhone = true }
            }
    }
}

private struct ContinueIntroScene: View {
    @Environment(AppModel.self) private var model
    let flow: OnboardingCoordinator

    var body: some View {
        let noSubscription = flow.canPlayAppleMusic == false
        SetupScaffold(flow: flow, showsBack: false, trailing: .none) {
            SongSeats(moves: true)
            Headline(text: "Take your music with you.")
            Explanation(text: "Take what’s playing to your iPhone, from the same point and with your Up Next queue. Back at your desk, your Mac picks the song up where you left off.")
            if noSubscription {
                Note(title: "Needs Apple Music.", text: "Continue Listening plays the song in Apple Music on this iPhone, which needs a subscription. You can set it up later from Second Chair.")
            } else {
                Text("Uses Apple Music on this iPhone. You can set it up later from Second Chair.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } actions: {
            if noSubscription {
                PrimaryButton("Done") { flow.finish() }
            } else {
                PrimaryButton("Set Up Continue Listening") { flow.go(.continueMusic) }
                SecondaryButton("Maybe Later") { flow.finish() }
            }
        }
        .task { await flow.checkAppleMusic() }
    }
}

private struct ContinueMusicScene: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let flow: OnboardingCoordinator
    @State private var showCode = false

    var body: some View {
        let connection = flow.facts(for: model).musicConnection
        let connected = connection == .connected
        SetupScaffold(flow: flow, trailing: .notNow { flow.finish() }) {
            MacPicture(part: connected ? .connectedToMusic : showCode ? .musicCode : .connectToMusic)
                .animation(.smooth, value: showCode)
            DeviceLabel(onMac: true, text: "On your Mac")
            Headline(text: "Connect Music on your Mac.")
            Explanation(text: "Click ♪, then **\(MacMenuText.connectToMusic)** In Music, choose Second Chair under Devices and type the four-digit code.")
            if connected {
                StatusLine(done: true, text: "Connected to Music")
            } else if connection == nil {
                Note(title: "This Mac can’t tell your iPhone when it’s done.", text: "Update Second Chair for Mac, or carry on once Music says it’s connected.",
                     actionTitle: "It’s Connected") { flow.go(.continueAccess) }
            } else {
                StatusLine(text: "Waiting for Music on \(flow.macName(model))…")
                if flow.waitedLong {
                    Note(title: "Not connecting?", text: "The four-digit code goes into Music on your Mac, not here. It isn’t the six-digit pairing code.")
                } else {
                    Text("A new four-digit code, typed into Music on your Mac. Not the six-digit one.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } actions: {
            EmptyView()
        }
        .task {
            // Both halves of the step in turn: the menu item, then where the code goes.
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                showCode.toggle()
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(90))
            flow.markWaitedLong()
        }
    }
}

private struct ContinueAccessScene: View {
    let flow: OnboardingCoordinator

    var body: some View {
        if flow.accessRefused {
            SetupScaffold(flow: flow, trailing: .none) {
                SongSeats(startOnPhone: true)
                DeviceLabel(onMac: false, text: "On this iPhone")
                Headline(text: "Apple Music is off for Second Chair.")
                Explanation(text: "Continue Listening needs it to play your music here. You can turn it on in Settings, under Second Chair.")
            } actions: {
                PrimaryButton("Open Settings") { flow.openSettings() }
                SecondaryButton("Maybe Later") { flow.finish() }
            }
        } else {
            SetupScaffold(flow: flow, trailing: .notNow { flow.finish() }) {
                SongSeats(startOnPhone: true)
                DeviceLabel(onMac: false, text: "On this iPhone")
                Headline(text: "Let it play here.")
                Explanation(text: "When you take your music with you, Second Chair starts it in Apple Music on this iPhone. iOS will ask you to allow that.")
            } actions: {
                PrimaryButton("Continue") { Task { await flow.askForAppleMusic() } }
            }
        }
    }
}

private struct ContinueReadyScene: View {
    let flow: OnboardingCoordinator

    var body: some View {
        SetupScaffold(flow: flow, showsBack: false, trailing: .none) {
            SongSeats(startOnPhone: true)
            Headline(text: "Ready to go.")
            Explanation(text: "Leaving your desk? Tap **Continue on iPhone** in Second Chair. Back at your Mac, choose **\(MacMenuText.continueFromIPhone)** in the ♪ menu.")
        } actions: {
            PrimaryButton("Start Listening") { flow.finish() }
        }
    }
}

// MARK: - Help

private struct SetupHelp: View {
    @Environment(AppModel.self) private var model
    let flow: OnboardingCoordinator

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("I can’t find ♪ on my Mac", "Open Second Chair from Applications. Don’t have it? Go back to the first step and send yourself the link.")
                    row("The code doesn’t work", "Codes work once and expire after five minutes. Choose \(MacMenuText.pairIPhone) again for a new one.")
                    row("Nothing shows up on my iPhone", "Music needs to be playing on your Mac, with Second Chair open here.")
                }
                Section {
                    Button("Start Setup Again") {
                        flow.showingHelp = false
                        flow.go(model.pairedMac == nil ? .macApp : .play)
                    }
                    Link("Full Guide at madewithmerritt.com", destination: URL(string: "https://madewithmerritt.com/second-chair/getting-started/")!)
                }
            }
            .navigationTitle("Setup Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { flow.showingHelp = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
