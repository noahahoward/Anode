import Foundation

/// The layout data for every Mac family, transcribed from the approved mockup
/// (`docs/superpowers/hardware-view-assets/mockup-source.html`, its `LAYOUTS`
/// object and the `DRAW` functions for the positions that are not in it).
///
/// The MacBook Pro layout sits on a straightened teardown photo: positions are
/// written in the original photo's pixels and mapped through `PhotoWarp`
/// exactly as the mockup's `P()` and `PS()` do. The other layouts are drawn, in
/// plain drawing units.
enum HardwareLayouts {

    // MARK: Families

    static let macBookPro14ProMax = photoLayout(family: .macBookPro14ProMax,
                                                title: "MacBook Pro 14″")
    static let macBookPro16ProMax = photoLayout(family: .macBookPro16ProMax,
                                                title: "MacBook Pro 16″",
                                                note: "This 16″ picture reuses the 14″ Pro layout and photo.")
    static let macBookPro14Base = makeMacBookPro14Base()
    static let macBookNeo = makeMacBookNeo()
    static let macMiniM4 = makeMacMini()
    static let generic = makeGeneric()

    // MARK: Helpers

    private static let warp = PhotoWarp.straightened

    /// Original-photo pixel to drawing units (the mockup's `P`).
    private static func pt(_ px: Double, _ py: Double) -> HWPoint {
        warp.drawingPoint(photoX: px, photoY: py)
    }

    /// Original-photo length to drawing units (the mockup's `PS`).
    private static func ps(_ v: Double) -> Double {
        warp.drawingLength(v)
    }

    /// A photo-pixel rectangle as a rounded drawing rectangle (the mockup's `FR`).
    private static func fr(_ px: Double, _ py: Double, _ pw: Double, _ ph: Double) -> HWRect {
        let p = pt(px, py)
        return HWRect(x: p.x.rounded(), y: p.y.rounded(),
                      w: ps(pw).rounded(), h: ps(ph).rounded())
    }

    /// A fraction of the chassis photo to drawing units (the mockup's `PF`).
    private static func pf(_ fx: Double, _ fy: Double) -> HWPoint {
        HWPoint(x: PhotoWarp.frameX + fx * PhotoWarp.frameWidth,
                y: PhotoWarp.frameY + fy * warp.frameHeight)
    }

    private static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> HWRect {
        HWRect(x: x, y: y, w: w, h: h)
    }

    /// A rectangle from the mockup's `[x, y, w, h]` array form.
    private static func rect(_ a: [Double]) -> HWRect {
        HWRect(x: a[0], y: a[1], w: a[2], h: a[3])
    }

    private static func union(_ rs: [HWRect]) -> HWRect {
        var x0 = Double.greatestFiniteMagnitude
        var y0 = Double.greatestFiniteMagnitude
        var x1 = -Double.greatestFiniteMagnitude
        var y1 = -Double.greatestFiniteMagnitude
        for r in rs {
            x0 = min(x0, r.x)
            y0 = min(y0, r.y)
            x1 = max(x1, r.x + r.w)
            y1 = max(y1, r.y + r.h)
        }
        return HWRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    private static func part(_ name: String, _ a: [Double], roles: [String] = []) -> HardwarePart {
        HardwarePart(name: name, rect: rect(a), roles: roles)
    }

    // MARK: Component builders (drawn layouts)

    /// A component that is just a rectangle with an optional jump target.
    private static func box(_ id: String,
                            _ kind: HardwareComponentKind,
                            _ a: [Double],
                            _ confidence: Confidence = .verified,
                            jump: [Double]? = nil,
                            label: String? = nil,
                            flags: [String] = [],
                            text: [String] = []) -> HardwareComponent {
        HardwareComponent(id: id, kind: kind, rect: rect(a), confidence: confidence,
                          jump: jump.map { rect($0) }, jumpLabel: label,
                          flags: flags, text: text)
    }

    private static func drawnFan(_ index: Int, cx: Double, cy: Double,
                                 _ confidence: Confidence,
                                 jump: [Double], label: String) -> HardwareComponent {
        let r = 78.0
        return HardwareComponent(id: "fan\(index)", kind: .fan(index: index),
                                 rect: HWRect(x: cx - r, y: cy - r, w: 2 * r, h: 2 * r),
                                 points: [HWPoint(x: cx, y: cy)],
                                 confidence: confidence,
                                 jump: rect(jump), jumpLabel: label)
    }

    private static func soc(_ a: [Double], die: [Double],
                            _ confidence: Confidence = .verified) -> HardwareComponent {
        HardwareComponent(id: "soc", kind: .soc, rect: rect(a), confidence: confidence,
                          parts: [part("die", die)])
    }

    private static func memory(dies: [[Double]], bar: [Double], pkg: [Double],
                               _ confidence: Confidence,
                               flags: [String] = [],
                               jump: [Double]) -> HardwareComponent {
        var parts: [HardwarePart] = []
        for (i, d) in dies.enumerated() {
            parts.append(part("die\(i)", d))
        }
        parts.append(part("bar", bar))
        return HardwareComponent(id: "mem", kind: .memory, rect: rect(pkg),
                                 confidence: confidence, jump: rect(jump),
                                 jumpLabel: "Memory", parts: parts, flags: flags)
    }

    private static func drawnPipe(x0: Double, x1: Double, y: Double, h: Double,
                                  split: Double, _ confidence: Confidence,
                                  flags: [String] = [],
                                  jump: [Double]) -> HardwareComponent {
        HardwareComponent(id: "pipe", kind: .heatPipe,
                          rect: HWRect(x: x0, y: y - h / 2, w: x1 - x0, h: h),
                          confidence: confidence, jump: rect(jump), jumpLabel: "CPU · GPU",
                          flags: ["cpuSideLeft", "dieSideInferred"] + flags,
                          values: ["split": split])
    }

    private static func drawnSSD(chips: [[Double]], tx: [Double], boxRect: [Double],
                                 _ confidence: Confidence,
                                 jump: [Double]) -> HardwareComponent {
        var parts: [HardwarePart] = []
        for (i, c) in chips.enumerated() {
            parts.append(part("chip\(i)", c))
        }
        // `tx` is [x, y, width] of the capacity text line: a zero-height part.
        parts.append(part("tx", [tx[0], tx[1], tx[2], 0]))
        return HardwareComponent(id: "ssd", kind: .storage, rect: rect(boxRect),
                                 confidence: confidence, jump: rect(jump),
                                 jumpLabel: "Storage", parts: parts)
    }

    private static func drawnAdapter(_ a: [Double], port: [Double]?, usbc: [[Double]],
                                     flags: [String] = [],
                                     values: [String: Double] = [:],
                                     jump: [Double]) -> HardwareComponent {
        var parts: [HardwarePart] = []
        if let port = port {
            parts.append(part("port", port))
        }
        for (i, u) in usbc.enumerated() {
            parts.append(part("usbc\(i)", u))
        }
        return HardwareComponent(id: "power-in", kind: .powerIn, rect: rect(a),
                                 confidence: .verified, jump: rect(jump),
                                 jumpLabel: "Power in", parts: parts,
                                 flags: flags, values: values)
    }

    private static func cell(_ n: Int, _ a: [Double], _ roles: [String]) -> HardwarePart {
        part("cell\(n)", a, roles: roles)
    }

    private static func drawnBattery(cells: [HardwarePart], _ confidence: Confidence,
                                     flags: [String] = [],
                                     jump: HWRect) -> HardwareComponent {
        HardwareComponent(id: "battery", kind: .battery,
                          rect: union(cells.map { $0.rect }),
                          confidence: confidence, jump: jump, jumpLabel: "Battery",
                          parts: cells, flags: flags)
    }

    // MARK: MacBook Pro on the teardown photo

    /// The heat pipe's symmetric path in straightened-photo pixels as u, v
    /// pairs (from `pipe-symmetric.json`). The centre line is u = 849.643.
    private static let pipePathUV: [Double] = [
        221.1, 146.4, 227.0, 146.4, 232.8, 146.4, 238.6, 146.4,
        244.4, 146.4, 250.3, 146.4, 256.1, 146.4, 261.9, 146.4,
        267.8, 146.4, 273.6, 146.4, 279.4, 146.4, 285.3, 146.4,
        291.1, 146.4, 296.9, 146.4, 302.7, 146.4, 308.6, 146.4,
        314.4, 146.4, 320.2, 146.4, 326.1, 146.4, 331.9, 146.4,
        337.7, 146.4, 343.5, 146.4, 349.4, 146.4, 355.2, 146.4,
        361.0, 146.4, 366.9, 146.4, 372.7, 146.4, 378.5, 146.4,
        384.4, 146.4, 390.2, 146.4, 396.0, 146.4, 401.8, 146.4,
        407.7, 146.4, 413.5, 146.4, 419.3, 146.4, 425.2, 146.4,
        431.0, 146.4, 436.8, 146.4, 442.7, 146.4, 448.5, 146.4,
        454.3, 146.4, 460.1, 146.4, 466.0, 146.4, 471.8, 146.4,
        477.6, 146.4, 483.5, 146.4, 489.3, 146.4, 495.1, 146.4,
        500.9, 146.4, 506.8, 146.4, 512.6, 146.4, 518.4, 146.4,
        524.3, 146.6, 530.1, 146.9, 535.9, 147.7, 541.6, 148.9,
        547.1, 150.7, 552.2, 153.4, 556.8, 157.0, 560.5, 161.5,
        563.2, 166.7, 565.2, 172.1, 566.8, 177.6, 568.3, 183.1,
        569.7, 188.5, 571.1, 193.9, 572.7, 199.2, 574.7, 204.4,
        577.0, 209.6, 579.6, 214.6, 582.5, 219.6, 585.8, 224.3,
        589.4, 228.9, 593.2, 233.2, 597.3, 237.3, 601.6, 241.2,
        606.1, 244.9, 610.8, 248.4, 615.7, 251.6, 620.7, 254.7,
        625.8, 257.5, 631.0, 260.1, 636.2, 262.5, 641.6, 264.8,
        647.1, 266.8, 652.6, 268.7, 658.1, 270.4, 663.7, 272.0,
        669.4, 273.4, 675.1, 274.7, 680.8, 275.8, 686.5, 276.7,
        692.3, 277.5, 698.1, 278.0, 703.9, 278.4, 709.7, 278.6,
        715.6, 278.6, 721.4, 278.6, 727.2, 278.6, 733.0, 278.6,
        738.9, 278.6, 744.7, 278.6, 750.5, 278.6, 756.4, 278.6,
        762.2, 278.6, 768.0, 278.6, 773.9, 278.6, 779.7, 278.6,
        785.5, 278.6, 791.3, 278.6, 797.2, 278.6, 803.0, 278.6,
        808.8, 278.6, 814.7, 278.6, 820.5, 278.6, 826.3, 278.6,
        832.2, 278.6, 838.0, 278.6, 843.8, 278.6, 849.6, 278.6,
        855.5, 278.6, 861.3, 278.6, 867.1, 278.6, 873.0, 278.6,
        878.8, 278.6, 884.6, 278.6, 890.5, 278.6, 896.3, 278.6,
        902.1, 278.6, 907.9, 278.6, 913.8, 278.6, 919.6, 278.6,
        925.4, 278.6, 931.3, 278.6, 937.1, 278.6, 942.9, 278.6,
        948.7, 278.6, 954.6, 278.6, 960.4, 278.6, 966.2, 278.6,
        972.1, 278.6, 977.9, 278.6, 983.7, 278.6, 989.6, 278.6,
        995.4, 278.4, 1001.2, 278.0, 1007.0, 277.5, 1012.8, 276.7,
        1018.5, 275.8, 1024.2, 274.7, 1029.9, 273.4, 1035.6, 272.0,
        1041.2, 270.4, 1046.7, 268.7, 1052.2, 266.8, 1057.7, 264.8,
        1063.0, 262.5, 1068.3, 260.1, 1073.5, 257.5, 1078.6, 254.7,
        1083.6, 251.6, 1088.5, 248.4, 1093.1, 244.9, 1097.7, 241.2,
        1102.0, 237.3, 1106.1, 233.2, 1109.9, 228.9, 1113.5, 224.3,
        1116.7, 219.6, 1119.7, 214.6, 1122.3, 209.6, 1124.6, 204.4,
        1126.6, 199.2, 1128.2, 193.9, 1129.6, 188.5, 1131.0, 183.1,
        1132.5, 177.6, 1134.1, 172.1, 1136.1, 166.7, 1138.8, 161.5,
        1142.5, 157.0, 1147.0, 153.4, 1152.2, 150.7, 1157.7, 148.9,
        1163.4, 147.7, 1169.2, 146.9, 1175.0, 146.6, 1180.9, 146.4,
        1186.7, 146.4, 1192.5, 146.4, 1198.3, 146.4, 1204.2, 146.4,
        1210.0, 146.4, 1215.8, 146.4, 1221.7, 146.4, 1227.5, 146.4,
        1233.3, 146.4, 1239.1, 146.4, 1245.0, 146.4, 1250.8, 146.4,
        1256.6, 146.4, 1262.5, 146.4, 1268.3, 146.4, 1274.1, 146.4,
        1280.0, 146.4, 1285.8, 146.4, 1291.6, 146.4, 1297.4, 146.4,
        1303.3, 146.4, 1309.1, 146.4, 1314.9, 146.4, 1320.8, 146.4,
        1326.6, 146.4, 1332.4, 146.4, 1338.2, 146.4, 1344.1, 146.4,
        1349.9, 146.4, 1355.7, 146.4, 1361.6, 146.4, 1367.4, 146.4,
        1373.2, 146.4, 1379.1, 146.4, 1384.9, 146.4, 1390.7, 146.4,
        1396.5, 146.4, 1402.4, 146.4, 1408.2, 146.4, 1414.0, 146.4,
        1419.9, 146.4, 1425.7, 146.4, 1431.5, 146.4, 1437.3, 146.4,
        1443.2, 146.4, 1449.0, 146.4, 1454.8, 146.4, 1460.7, 146.4,
        1466.5, 146.4, 1472.3, 146.4, 1478.2, 146.4
    ]

    /// The pipe path in drawing units: x = 40 + u * 1020/1700, y = 468 + v * 1020/1700.
    private static func pipePoints() -> [HWPoint] {
        var out: [HWPoint] = []
        var i = 0
        while i + 1 < pipePathUV.count {
            out.append(HWPoint(x: PhotoWarp.frameX + pipePathUV[i] * warp.frameScale,
                               y: PhotoWarp.frameY + pipePathUV[i + 1] * warp.frameScale))
            i += 2
        }
        return out
    }

    private static func photoFan(_ index: Int, photoX: Double, photoY: Double,
                                 jump: HWRect, label: String) -> HardwareComponent {
        let c = pt(photoX, photoY)
        let r = ps(126)
        return HardwareComponent(id: "fan\(index)", kind: .fan(index: index),
                                 rect: HWRect(x: c.x - r, y: c.y - r, w: 2 * r, h: 2 * r),
                                 points: [c], confidence: .verified,
                                 jump: jump, jumpLabel: label)
    }

    /// A battery cell placed in photo pixels.
    private static func photoCell(_ n: Int, _ px: Double, _ py: Double,
                                  _ pw: Double, _ ph: Double,
                                  _ roles: [String]) -> HardwarePart {
        let p = pt(px, py)
        return HardwarePart(name: "cell\(n)",
                            rect: HWRect(x: p.x, y: p.y, w: ps(pw), h: ps(ph)),
                            roles: roles)
    }

    /// `note`, when given, is one line of words drawn centred on the hinge strip between the lid and the photo (the 16-inch
    /// layout uses it to say that it shares the 14-inch Pro's data and photo).
    private static func photoLayout(family: MacFamily, title: String, note: String? = nil) -> HardwareLayout {
        let frameH = warp.frameHeight
        let photoFrame = HWRect(x: PhotoWarp.frameX, y: PhotoWarp.frameY,
                                w: PhotoWarp.frameWidth, h: frameH)

        // Pipe: the symmetric path, with the CPU and GPU pill centres on it.
        let s = warp.frameScale
        let cpuPill = HWPoint(x: PhotoWarp.frameX + 750.9089615705748 * s,
                              y: PhotoWarp.frameY + 278.87756264454447 * s)
        let gpuPill = HWPoint(x: PhotoWarp.frameX + 948.3769724687713 * s,
                              y: PhotoWarp.frameY + 278.87756264454447 * s)
        let pipeBox = fr(680, 150, 920, 320)
        let pipe = HardwareComponent(id: "pipe", kind: .heatPipe, rect: pipeBox,
                                     points: pipePoints(), confidence: .verified,
                                     jump: pipeBox, jumpLabel: "CPU · GPU",
                                     anchors: ["cpu": cpuPill, "gpu": gpuPill],
                                     flags: ["cpuSideLeft", "dieSideInferred"])

        // Memory: one module each side of the SoC, as fractions of the chassis.
        func module(_ fx0: Double, _ fx1: Double) -> HWRect {
            let p = pf(fx0, 0.234)
            return HWRect(x: p.x, y: p.y, w: (fx1 - fx0) * PhotoWarp.frameWidth, h: 0.22 * frameH)
        }
        let modL = module(0.318, 0.416)
        let modR = module(0.582, 0.68)
        let mem = HardwareComponent(id: "mem", kind: .memory, rect: union([modL, modR]),
                                    confidence: .inferred,
                                    jump: rect(345, 615, 450, 200), jumpLabel: "Memory",
                                    parts: [HardwarePart(name: "moduleL", rect: modL),
                                            HardwarePart(name: "moduleR", rect: modR)])

        // Storage: two NAND chips low on the board and the readout plate between.
        let a0 = pf(0.38, 0.516)
        let nandA = HWRect(x: a0.x, y: a0.y, w: 0.037 * PhotoWarp.frameWidth, h: 0.056 * frameH)
        let b0 = pf(0.614, 0.462)
        let nandB = HWRect(x: b0.x, y: b0.y, w: 0.102 * PhotoWarp.frameWidth, h: 0.118 * frameH)
        let plate = HWRect(x: 474, y: PhotoWarp.frameY + frameH * 0.49, w: 184, h: 54)
        let ssd = HardwareComponent(id: "ssd", kind: .storage,
                                    rect: union([nandA, nandB, plate]),
                                    confidence: .inferred,
                                    jump: rect(415, 780, 370, 110), jumpLabel: "Storage",
                                    parts: [HardwarePart(name: "nandA", rect: nandA),
                                            HardwarePart(name: "nandB", rect: nandB),
                                            HardwarePart(name: "plate", rect: plate)])

        let wifiOrigin = pt(1992, 590)
        let wifi = HardwareComponent(id: "wifi", kind: .wifi,
                                     rect: HWRect(x: wifiOrigin.x, y: wifiOrigin.y,
                                                  w: ps(250), h: 58),
                                     confidence: .inferred,
                                     jump: fr(1880, 400, 400, 230), jumpLabel: "Wi-Fi")

        let powerOrigin = pt(60, 95)
        let power = HardwareComponent(id: "power-in", kind: .powerIn,
                                      rect: HWRect(x: powerOrigin.x, y: powerOrigin.y,
                                                   w: ps(500), h: ps(100)),
                                      confidence: .verified,
                                      jump: fr(40, 70, 560, 320), jumpLabel: "Power in",
                                      anchors: ["port": pt(150, 300)])

        let cells: [HardwarePart] = [
            photoCell(0, 205, 885, 395, 315, ["charge"]),
            photoCell(1, 130, 1215, 470, 295, ["temp"]),
            photoCell(2, 690, 955, 430, 425, ["state"]),
            photoCell(3, 1160, 955, 430, 425, ["graph"]),
            photoCell(4, 1685, 885, 405, 315, ["draw"]),
            photoCell(5, 1690, 1215, 480, 295, ["health"])
        ]
        let battery = HardwareComponent(id: "battery", kind: .battery,
                                        rect: union(cells.map { $0.rect }),
                                        confidence: .verified,
                                        jump: fr(100, 860, 2100, 680), jumpLabel: "Battery",
                                        parts: cells, flags: ["plated"])

        var components: [HardwareComponent] = [
            box("display", .display, [58, 26, 984, 398], .verified,
                jump: [40, 10, 1020, 430], label: "Display"),
            box("antenna", .antenna, [152, 507, 796, 15], .inferred),
            photoFan(0, photoX: 434, photoY: 488, jump: fr(230, 260, 490, 640), label: "Fan 1"),
            photoFan(1, photoX: 1845, photoY: 481, jump: fr(1560, 260, 500, 640), label: "Fan 2"),
            pipe,
            mem,
            ssd,
            wifi,
            power,
            battery
        ]
        if let note = note {
            components.append(box("note", .note, [550, 456, 0, 0], .verified,
                                  flags: ["centered"], text: [note]))
        }

        return HardwareLayout(family: family, title: title,
                              size: rect(0, 0, 1100, 1205),
                              photoResource: "macbook-pro-teardown",
                              photoFrame: photoFrame,
                              components: components)
    }

    // MARK: MacBook Pro 14 base chip (drawn, one fan)

    private static func makeMacBookPro14Base() -> HardwareLayout {
        let components: [HardwareComponent] = [
            box("display", .display, [58, 26, 984, 398], .verified,
                jump: [40, 10, 1020, 430], label: "Display"),
            box("antenna", .antenna, [130, 474, 840, 18], .inferred),
            box("board", .board, [300, 498, 500, 374], .verified),
            drawnFan(0, cx: 900, cy: 652, .inferred, jump: [800, 540, 200, 290], label: "Fan"),
            soc([330, 572, 440, 160], die: [475, 600, 150, 104]),
            memory(dies: [[344, 584, 112, 136], [644, 584, 112, 136]],
                   bar: [352, 702, 396, 14], pkg: [330, 572, 440, 160], .verified,
                   jump: [320, 560, 460, 190]),
            drawnPipe(x0: 430, x1: 818, y: 652, h: 30, split: 560, .verified,
                      flags: ["short"], jump: [420, 560, 420, 200]),
            box("wifi", .wifi, [590, 502, 170, 64], .inferred,
                jump: [470, 470, 500, 110], label: "Wi-Fi"),
            drawnSSD(chips: [[418, 760, 84, 46], [666, 760, 90, 46]], tx: [418, 826, 338],
                     boxRect: [406, 750, 362, 124], .verified, jump: [370, 740, 360, 140]),
            drawnAdapter([64, 498, 190, 44], port: [40, 508, 22, 24],
                         usbc: [[40, 590, 22, 16], [40, 624, 22, 16]],
                         jump: [40, 480, 240, 80]),
            box("spkL", .speaker, [62, 882, 38, 210], .verified),
            box("spkR", .speaker, [1000, 882, 38, 210], .verified),
            box("trackpad", .trackpad, [392, 872, 316, 232], .verified),
            drawnBattery(cells: [
                cell(0, [110, 882, 280, 100], ["charge"]),
                cell(1, [110, 992, 280, 100], ["temp"]),
                cell(2, [410, 882, 280, 100], ["state"]),
                cell(3, [410, 992, 280, 100], ["graph"]),
                cell(4, [710, 882, 280, 100], ["draw"]),
                cell(5, [710, 992, 280, 100], ["health"])
            ], .verified, jump: rect(100, 870, 900, 236))
        ]
        return HardwareLayout(family: .macBookPro14Base,
                              title: "MacBook Pro 14″ · one fan",
                              size: rect(0, 0, 1100, 1130),
                              photoResource: nil, photoFrame: nil,
                              components: components)
    }

    // MARK: MacBook Neo (drawn, fanless)

    private static func makeMacBookNeo() -> HardwareLayout {
        let components: [HardwareComponent] = [
            box("display", .display, [58, 26, 984, 398], .verified,
                jump: [40, 10, 1020, 430], label: "Display",
                text: ["2408 × 1506", "Liquid Retina"]),
            box("antenna", .antenna, [130, 474, 840, 18], .inferred),
            box("board", .board, [350, 498, 400, 300], .verified),
            soc([420, 534, 260, 150], die: [470, 556, 160, 106]),
            memory(dies: [[430, 544, 240, 38]], bar: [440, 660, 220, 12],
                   pkg: [420, 534, 260, 150], .verified,
                   flags: ["compact", "stack"], jump: [410, 520, 290, 180]),
            drawnPipe(x0: 380, x1: 720, y: 610, h: 34, split: 550, .verified,
                      flags: ["spreader"], jump: [370, 520, 360, 170]),
            box("wifi", .wifi, [700, 510, 110, 70], .inferred,
                jump: [600, 470, 260, 120], label: "Wi-Fi", flags: ["small"]),
            drawnSSD(chips: [[400, 716, 110, 50]], tx: [524, 722, 226],
                     boxRect: [390, 706, 370, 70], .verified, jump: [380, 700, 390, 90]),
            drawnAdapter([64, 560, 200, 44], port: nil,
                         usbc: [[40, 574, 22, 16], [40, 616, 22, 16]],
                         flags: ["usbcPower"], values: ["adapterW": 30],
                         jump: [40, 540, 260, 100]),
            box("spkL", .speaker, [62, 840, 38, 252], .verified),
            box("spkR", .speaker, [1000, 840, 38, 252], .verified),
            box("trackpad", .trackpad, [392, 880, 316, 224], .verified),
            drawnBattery(cells: [
                cell(0, [110, 840, 430, 252], ["charge", "temp", "state"]),
                cell(1, [560, 840, 430, 252], ["graph", "draw", "health"])
            ], .verified, jump: rect(100, 830, 900, 270)),
            box("note", .note, [84, 700, 0, 0], .verified,
                text: ["Fanless.", "Cooled passively", "through the case."])
        ]
        return HardwareLayout(family: .macBookNeo,
                              title: "MacBook Neo · fanless",
                              size: rect(0, 0, 1100, 1130),
                              photoResource: nil, photoFrame: nil,
                              components: components)
    }

    // MARK: Mac mini M4 (drawn, desktop)

    private static func makeMacMini() -> HardwareLayout {
        let components: [HardwareComponent] = [
            box("psu", .psu, [220, 60, 660, 100], .verified,
                jump: [200, 40, 700, 140], label: "Power"),
            drawnFan(0, cx: 370, cy: 350, .verified, jump: [270, 240, 200, 310], label: "Fan"),
            soc([520, 270, 300, 180], die: [600, 300, 140, 100]),
            memory(dies: [[528, 278, 56, 164], [756, 278, 56, 164]],
                   bar: [536, 420, 264, 12], pkg: [520, 270, 300, 180], .verified,
                   flags: ["compact"], jump: [510, 240, 320, 230]),
            drawnPipe(x0: 450, x1: 790, y: 350, h: 28, split: 625, .verified,
                      jump: [440, 250, 360, 200]),
            drawnSSD(chips: [[240, 590, 100, 56]], tx: [240, 656, 230],
                     boxRect: [230, 580, 250, 110], .inferred, jump: [220, 570, 270, 130]),
            box("wifi", .wifi, [620, 590, 170, 64], .inferred,
                jump: [600, 570, 210, 110], label: "Wi-Fi"),
            box("antenna", .antenna, [215, 722, 670, 22], .inferred,
                text: ["BOTTOM PLATE · ANTENNA (approx.)"])
        ]
        return HardwareLayout(family: .macMiniM4,
                              title: "Mac mini",
                              size: rect(130, 0, 840, 800),
                              photoResource: nil, photoFrame: nil,
                              components: components)
    }

    // MARK: Generic fallback (drawn schematic)

    private static func makeGeneric() -> HardwareLayout {
        let components: [HardwareComponent] = [
            box("gboard", .board, [60, 40, 980, 1050], .inferred),
            drawnFan(0, cx: 230, cy: 210, .inferred, jump: [130, 100, 200, 300], label: "Fan 1"),
            drawnFan(1, cx: 870, cy: 210, .inferred, jump: [770, 100, 200, 300], label: "Fan 2"),
            soc([330, 140, 440, 160], die: [475, 168, 150, 104], .inferred),
            memory(dies: [[344, 152, 112, 136], [644, 152, 112, 136]],
                   bar: [352, 264, 396, 14], pkg: [330, 140, 440, 160], .inferred,
                   jump: [320, 130, 460, 190]),
            drawnPipe(x0: 310, x1: 790, y: 220, h: 30, split: 550, .inferred,
                      jump: [300, 130, 500, 180]),
            box("wifi", .wifi, [340, 370, 170, 64], .inferred,
                jump: [320, 350, 220, 100], label: "Wi-Fi"),
            drawnSSD(chips: [[600, 372, 90, 46]], tx: [560, 438, 316],
                     boxRect: [560, 360, 340, 110], .inferred, jump: [550, 350, 360, 130]),
            drawnBattery(cells: [
                cell(0, [110, 540, 880, 250], ["charge", "temp", "state"]),
                cell(1, [110, 810, 880, 260], ["graph", "draw", "health"])
            ], .inferred, jump: rect(80, 520, 940, 560)),
            box("gnote", .note, [110, 490, 0, 0], .inferred,
                text: ["Generic schematic.",
                       "Anode does not know this model’s internal layout yet, so every position here is approximate."])
        ]
        return HardwareLayout(family: .generic,
                              title: "Mac · layout not known",
                              size: rect(0, 0, 1100, 1130),
                              photoResource: nil, photoFrame: nil,
                              components: components)
    }
}
