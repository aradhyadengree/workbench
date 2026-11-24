import SwiftUI
import WebKit

struct PhoneSimulatorFrame: View {
    @Binding var activeDeviceUDID: String
    @State private var deviceName = "Phone 17 Pro Max"
    @State private var scale: CGFloat = 1
    @State private var isRotated = false
    @State private var showBezel = true
    @SceneStorage("phonePreviewTarget") private var currentMode: PhoneMode = .interactiveApp
    @ObservedObject var mobileBrowser: Browser
    var sharedAddress = false
    var webRequest: UUID? = nil
    @Environment(\.colorScheme) private var colorScheme

    enum PhoneMode: String {
        case interactiveApp
        case homeScreen
        case simulatorCapture
    }

    let devices = [
        "Phone 17 Pro Max",
        "Phone 17 Pro",
        "iPhone 16 Pro Max",
        "iPhone 16 Pro",
        "iPhone 15"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar matching reference screenshot
            HStack(spacing: 8) {
                Image(systemName: "iphone").foregroundStyle(.secondary)
                Picker("Mobile target", selection: $currentMode) {
                    Text("Mobile web").tag(PhoneMode.interactiveApp)
                    Text("iOS Simulator").tag(PhoneMode.simulatorCapture)
                    Text("Home screen").tag(PhoneMode.homeScreen)
                }.labelsHidden().accessibilityLabel("Mobile target")
                Spacer()
                if currentMode != .simulatorCapture {
                    Menu {
                        Picker("Device size", selection: $deviceName) {
                            ForEach(devices, id: \.self) { Text($0) }
                        }
                        Button("Zoom In") { scale = min(2, scale + 0.25) }
                        Button("Zoom Out") { scale = max(0.5, scale - 0.25) }
                        Button("Fit Phone to Pane") { scale = 1 }
                        Toggle("Device Bezel", isOn: $showBezel)
                    } label: { Image(systemName: "slider.horizontal.3") }
                    .menuStyle(.borderlessButton).fixedSize().help("Phone display settings")
                    Button { isRotated.toggle() } label: { Image(systemName: "rotate.right") }
                        .buttonStyle(.plain).help("Rotate phone viewport")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder)
                    .frame(height: 1)
            }

            // Viewport hosting Phone Device Frame
            if !sharedAddress && currentMode == .interactiveApp {
                HStack {
                    TextField("Product URL or localhost:3000", text: $mobileBrowser.address)
                        .onSubmit { mobileBrowser.go() }
                    Button("Load") { mobileBrowser.go() }
                }.padding(6)
            }
            if currentMode == .simulatorCapture {
                SimulatorPane(active: $activeDeviceUDID)
            } else if currentMode == .interactiveApp && !mobileBrowser.started {
                ContentUnavailableView("Phone preview", systemImage: "iphone", description: Text("Load a product URL above to open it on this phone."))
            } else {
                if !mobileBrowser.issue.isEmpty && currentMode == .interactiveApp {
                    Text(mobileBrowser.issue).font(.caption).foregroundStyle(.orange)
                }
                GeometryReader { bounds in
                    let factor = max(0.01, min((bounds.size.width - 20) / (phoneWidth + 24),
                                               (bounds.size.height - 20) / (phoneHeight + 24))) * scale
                    ScrollView([.horizontal, .vertical]) {
                        phoneFrame.scaleEffect(factor)
                            .frame(width: (phoneWidth + 24) * factor, height: (phoneHeight + 24) * factor)
                            .padding(8)
                            .frame(minWidth: bounds.size.width, minHeight: bounds.size.height)
                    }
                }
            }
        }
        .onChange(of: webRequest, initial: true) { if webRequest != nil { currentMode = .interactiveApp } }
    }

    private var portraitWidth: CGFloat {
        if deviceName.contains("Max") { return 430 }
        if deviceName == "iPhone 15" { return 393 }
        return 402
    }
    private var phoneWidth: CGFloat { isRotated ? portraitWidth * 2.16 : portraitWidth }
    private var phoneHeight: CGFloat { isRotated ? portraitWidth : portraitWidth * 2.16 }

    private var phoneFrame: some View {
        let cornerRadius: CGFloat = 46
        return ZStack {
            // Titanium Bezel
            if showBezel {
                RoundedRectangle(cornerRadius: cornerRadius + 4)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.28, green: 0.30, blue: 0.36),
                                Color(red: 0.16, green: 0.17, blue: 0.22),
                                Color(red: 0.24, green: 0.26, blue: 0.32)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: phoneWidth + 24, height: phoneHeight + 24)
                    .shadow(color: Color.black.opacity(0.45), radius: 25, x: 0, y: 15)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius + 4)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
                    }
            }

            // Screen Area
            ZStack(alignment: .top) {
                // Background Screen Content
                Group {
                    switch currentMode {
                    case .interactiveApp:
                        // Interactive WebKit mobile surface
                        WebSurface(page: mobileBrowser.page).id(ObjectIdentifier(mobileBrowser.page))
                    case .homeScreen:
                        homeScreenView
                    case .simulatorCapture:
                        EmptyView()
                    }
                }
                .frame(width: phoneWidth, height: phoneHeight)
                .background(Color(red: 0.10, green: 0.12, blue: 0.18))

                // Top Status Bar (Clock, Dynamic Island, Battery)
                VStack(spacing: 0) {
                    HStack {
                        // Clock
                        Text("5:15")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.leading, 24)

                        Spacer()

                        // Dynamic Island Pill
                        Capsule()
                            .fill(Color.black)
                            .frame(width: 96, height: 26)
                            .overlay(alignment: .trailing) {
                                Circle()
                                    .fill(Color(red: 0.15, green: 0.15, blue: 0.25))
                                    .frame(width: 9, height: 9)
                                    .padding(.trailing, 8)
                            }

                        Spacer()

                        // Signal & Battery
                        HStack(spacing: 5) {
                            Image(systemName: "cellularbars")
                            Image(systemName: "wifi")
                            Image(systemName: "battery.100")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.trailing, 24)
                    }
                    .padding(.top, 12)

                    Spacer()

                    // Home Indicator Line
                    Capsule()
                        .fill(Color.white.opacity(0.7))
                        .frame(width: 130, height: 4)
                        .padding(.bottom, 8)
                }
                .frame(width: phoneWidth, height: phoneHeight)
                .allowsHitTesting(false) // Let user touch the app underneath
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.black, lineWidth: 2)
            }
        }
    }

    // MARK: - Realistic iOS Home Screen (Matching Screenshot)
    private var homeScreenView: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 48)

            // Grid of iOS App Icons
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 4), spacing: 24) {
                appIcon("Preview", icon: "checkmark.seal.fill", bg: Color.cyan)
                appIcon("Utilities", icon: "folder.fill", bg: Color.gray)
                appIcon("Fitness", icon: "figure.walk", bg: Color.green)
                appIcon("Reminders", icon: "list.bullet", bg: Color.orange)

                appIcon("App", icon: "v.circle.fill", bg: Color(red: 0.15, green: 0.75, blue: 0.55))
                appIcon("Expo Go", icon: "triangle.fill", bg: Color.black)
                appIcon("Contacts", icon: "person.crop.circle.fill", bg: Color.blue)
                appIcon("Files", icon: "folder.badge.gearshape", bg: Color.cyan)
            }
            .padding(.horizontal, 24)

            Spacer()

            // Search pill
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption2)
                Text("Search").font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.2), in: Capsule())
            .foregroundStyle(.white)

            // Dock
            HStack(spacing: 20) {
                dockIcon("phone.fill", bg: Color.green)
                dockIcon("safari.fill", bg: Color.blue)
                dockIcon("message.fill", bg: Color.green)
                dockIcon("music.note", bg: Color.red)
            }
            .padding(14)
            .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 28))
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(red: 0.15, green: 0.40, blue: 0.85), Color(red: 0.05, green: 0.10, blue: 0.25)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func appIcon(_ title: String, icon: String, bg: Color) -> some View {
        Button {
            currentMode = .interactiveApp
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(bg)
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }.buttonStyle(.plain)
    }

    private func dockIcon(_ icon: String, bg: Color) -> some View {
        Button {
            currentMode = .interactiveApp
        } label: {
            RoundedRectangle(cornerRadius: 14)
                .fill(bg)
                .frame(width: 50, height: 50)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                }
        }.buttonStyle(.plain)
    }
}
