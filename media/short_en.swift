// 小黑短视频英文版：竖屏 1080×1920，40 秒，120 BPM，比中文版慢，每句话都看得清
// 用法：swiftc -O short_en.swift -o short_en && ./short_en xiaohei_short_en.mp4
//       ./short_en --still 1.0,5.5 outdir   只导出这几秒的 PNG 预览
// 素材来自 CodexDog 第一次启动时抠好的图：~/Library/Application Support/CodexDog
// 一拍 0.5 秒，所有动作都卡在拍子上；文字避开上下两头被平台界面挡住的区域
import AppKit
import AVFoundation
import CoreText

let W = 1080.0, H = 1920.0, FPS = 60.0, SUB = 3, DUR = 40.0
let BEAT = 0.5
func b(_ n: Double) -> Double { n * BEAT }
let SUP = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexDog")

// MARK: - 素材（idle/happy/dizzy 三张照片里带着摸它的手，这里只用没有手的）

func load(_ p: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(SUP.appendingPathComponent(p) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
func frames(_ dir: String) -> [CGImage] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: SUP.appendingPathComponent(dir).path)) ?? []
    return names.filter { $0.hasSuffix(".png") }.sorted().map { load(dir + "/" + $0) }
}
let SLEEP = load("sleep.png"), BELLY = load("belly.png"), SAUSAGE = load("sausage.png")
let BEG = frames("beg"), STAND = frames("stand"), LOOK = frames("look")

// MARK: - 数学

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeIn(_ x: Double) -> Double { x * x * x }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func lerp(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }
func spring(_ x: Double, freq: Double = 2.2, damp: Double = 0.5) -> Double {
    guard x > 0 else { return 0 }
    let w = 2 * .pi * freq, wd = w * sqrt(1 - damp * damp)
    return 1 - exp(-damp * w * x) * (cos(wd * x) + damp * w / wd * sin(wd * x))
}
func impulse(_ x: Double, decay: Double = 9) -> Double { x <= 0 ? 0 : x * decay * exp(1 - x * decay) }
func pingpong(_ f: [CGImage], _ t: Double, fps: Double) -> CGImage {
    let n = f.count
    guard n > 1 else { return f[0] }
    let period = 2 * n - 2
    let k = Int(max(0, t) * fps) % period
    return f[k < n ? k : period - k]
}
func hash(_ i: Int) -> Double { let x = sin(Double(i) * 12.9898) * 43758.5453; return x - floor(x) }

// MARK: - 画图（左上角为原点，y 向下）

var ctx: CGContext!

let INK: UInt32 = 0x111111, YELLOW: UInt32 = 0xffd60a, RED: UInt32 = 0xff3b30, GREEN: UInt32 = 0x2fd16b
let BLUE: UInt32 = 0x2f6fe0, WHITE: UInt32 = 0xffffff

func rgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255, alpha: a)
}
func lerpColor(_ a: UInt32, _ b: UInt32, _ x: Double) -> CGColor {
    func c(_ h: UInt32, _ s: UInt32) -> Double { Double((h >> s) & 0xff) / 255 }
    return CGColor(red: lerp(c(a, 16), c(b, 16), x), green: lerp(c(a, 8), c(b, 8), x),
                   blue: lerp(c(a, 0), c(b, 0), x), alpha: 1)
}
func fill(_ r: CGRect, _ c: CGColor, radius: Double = 0, shadow: Double = 0) {
    ctx.saveGState()
    if shadow > 0 { ctx.setShadow(offset: CGSize(width: 0, height: shadow / 3), blur: shadow, color: rgb(0x000000, 0.25)) }
    ctx.setFillColor(c)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2, r.height / 2),
                       cornerHeight: min(radius, r.width / 2, r.height / 2), transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}
func bg(_ c: UInt32) { fill(CGRect(x: -200, y: -200, width: W + 400, height: H + 400), rgb(c)) }
func glow(_ x: Double, _ y: Double, _ r: Double, _ c: UInt32, _ a: Double) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(c, a), rgb(c, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
}
/// 放射状的速度光芒（漫画感背景）
func rays(_ cx: Double, _ cy: Double, _ c: UInt32, _ a: Double, spin: Double, n: Int = 18) {
    ctx.saveGState()
    ctx.setFillColor(rgb(c, a))
    for i in 0..<n {
        let a0 = Double(i) / Double(n) * 2 * .pi + spin, a1 = a0 + .pi / Double(n)
        ctx.move(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx + cos(a0) * 3000, y: cy + sin(a0) * 3000))
        ctx.addLine(to: CGPoint(x: cx + cos(a1) * 3000, y: cy + sin(a1) * 3000))
        ctx.closePath()
    }
    ctx.fillPath()
    ctx.restoreGState()
}
func groundShadow(_ cx: Double, _ y: Double, _ w: Double, _ a: Double = 0.25) {
    ctx.saveGState()
    ctx.translateBy(x: cx, y: y)
    ctx.scaleBy(x: 1, y: 0.18)
    glow(0, 0, w / 2, 0x000000, a)
    ctx.restoreGState()
}
func dog(_ img: CGImage, cx: Double, bottom: Double, height: Double, alpha: Double = 1,
         flip: Bool = false, rot: Double = 0, sx: Double = 1, sy: Double = 1) {
    let w = height * Double(img.width) / Double(img.height)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: cx, y: bottom)
    ctx.rotate(by: rot)
    ctx.scaleBy(x: (flip ? -1 : 1) * sx, y: -sy)
    ctx.draw(img, in: CGRect(x: -w / 2, y: 0, width: w, height: height))
    ctx.restoreGState()
}

func font(_ size: Double, _ weight: String = "Semibold", mono: Bool = false) -> CTFont {
    // 英文用 Avenir Next：大字用最粗的 Heavy，小字用 DemiBold
    CTFontCreateWithName((mono ? "Menlo-Bold" : weight == "Semibold" ? "AvenirNext-Heavy" : "AvenirNext-DemiBold") as CFString, size, nil)
}
func ctline(_ s: String, _ f: CTFont, _ c: CGColor) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): c,
    ]))
}
func width(_ s: String, _ f: CTFont) -> Double { CTLineGetTypographicBounds(ctline(s, f, rgb(0)), nil, nil, nil) }

/// 短视频大字：白字（或彩字）+ 粗黑描边 + 投影，以 (x, y) 为中心
func pop(_ s: String, _ x: Double, _ y: Double, size: Double, color: UInt32 = WHITE, stroke: UInt32 = INK,
         alpha: Double = 1, scale: Double = 1, rot: Double = 0, mono: Bool = false) {
    guard alpha > 0.01, scale > 0.01 else { return }
    let f = font(size, mono: mono)
    let w = width(s, f)
    var asc: CGFloat = 0, desc: CGFloat = 0
    _ = CTLineGetTypographicBounds(ctline(s, f, rgb(0)), &asc, &desc, nil)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: x, y: y)
    ctx.rotate(by: rot)
    ctx.scaleBy(x: scale, y: scale)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    let pos = CGPoint(x: -w / 2, y: (asc - desc) / 2)
    // 描边
    ctx.setLineJoin(.round)
    ctx.setLineWidth(size * 0.16)
    ctx.setStrokeColor(rgb(stroke))
    ctx.setShadow(offset: CGSize(width: 0, height: size * 0.08), blur: 0, color: rgb(stroke))
    ctx.setTextDrawingMode(.stroke)
    ctx.textPosition = pos
    CTLineDraw(ctline(s, f, rgb(stroke)), ctx)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setTextDrawingMode(.fill)
    ctx.textPosition = pos
    CTLineDraw(ctline(s, f, rgb(color)), ctx)
    ctx.restoreGState()
}
/// 砸下来的字：从大到小弹到位置上
func slam(_ s: String, _ t: Double, t0: Double, t1: Double = 1e9, x: Double = W / 2, y: Double, size: Double,
          color: UInt32 = WHITE, rot: Double = 0, stroke: UInt32 = INK) {
    guard t >= t0, t < t1 + 0.15 else { return }
    let p = spring(t - t0, freq: 3.2, damp: 0.45)
    let out = prog(t, t1, t1 + 0.12)
    pop(s, x, y, size: size, color: color, stroke: stroke, alpha: clamp01((t - t0) / 0.05) * (1 - out),
        scale: lerp(1.9, 1, p) * (1 - out * 0.5), rot: rot)
}
func plain(_ s: String, _ x: Double, _ y: Double, size: Double, weight: String = "Semibold", color: CGColor = rgb(INK),
           alpha: Double = 1, align: Double = 0.5, mono: Bool = false) {
    guard alpha > 0.01 else { return }
    let f = font(size, weight, mono: mono)
    let l = ctline(s, f, color)
    var asc: CGFloat = 0, desc: CGFloat = 0
    let w = CTLineGetTypographicBounds(l, &asc, &desc, nil)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x - w * align, y: y + (asc - desc) / 2)
    CTLineDraw(l, ctx)
    ctx.restoreGState()
}

func arrow(_ x: Double, _ y: Double, scale: Double = 2.4, alpha: Double = 1) {
    guard scale > 0.01, alpha > 0.01 else { return }
    let pts: [(Double, Double)] = [(0, 0), (0, 34), (9, 26), (15, 40), (21, 37), (15, 24), (27, 24)]
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: x, y: y)
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: rgb(0x000000, 0.35))
    ctx.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
    for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
    ctx.closePath()
    ctx.setFillColor(rgb(INK))
    ctx.setStrokeColor(rgb(WHITE))
    ctx.setLineWidth(2)
    ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()
}
func sausage(_ x: Double, _ y: Double, height: Double = 220, scale: Double = 1, rot: Double = 0) {
    guard scale > 0.01 else { return }
    let h = height * scale, w = h * Double(SAUSAGE.width) / Double(SAUSAGE.height)
    ctx.saveGState()
    ctx.translateBy(x: x, y: y)
    ctx.rotate(by: rot)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 14, color: rgb(0x000000, 0.35))
    ctx.draw(SAUSAGE, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
    ctx.restoreGState()
}
func card(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double, hue: Int, alpha: Double = 1, scale: Double = 1, rot: Double = 0) {
    guard alpha > 0.01, scale > 0.01 else { return }
    let colors: [UInt32] = [0x5b8def, 0xf0a04b, 0x4cb782, 0xe0607e, 0x9b6ef3, 0x2ab0c5]
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: rot)
    ctx.scaleBy(x: scale, y: scale)
    let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    fill(r, rgb(WHITE), radius: 14, shadow: 12)
    fill(CGRect(x: r.minX, y: r.minY, width: w, height: h * 0.16), rgb(0xe9e9ee), radius: 14)
    fill(CGRect(x: r.minX + w * 0.08, y: r.minY + h * 0.27, width: w * 0.5, height: h * 0.4), rgb(colors[hue % 6]), radius: 8)
    for i in 0..<3 {
        fill(CGRect(x: r.minX + w * 0.64, y: r.minY + h * (0.3 + Double(i) * 0.14), width: w * 0.26, height: h * 0.06), rgb(0xd5d5dc), radius: 3)
    }
    fill(CGRect(x: r.minX + w * 0.08, y: r.minY + h * 0.76, width: w * 0.82, height: h * 0.07), rgb(0xd5d5dc), radius: 3)
    ctx.restoreGState()
}
func bar(_ x: Double, _ y: Double, _ w: Double, frac: Double, flash: Double = 0) {
    fill(CGRect(x: x - 8, y: y - 8, width: w + 16, height: 72), rgb(INK), radius: 36)
    let c = frac > 0.5 ? lerpColor(0xffb020, GREEN, (frac - 0.5) * 2) : lerpColor(RED, 0xffb020, frac * 2)
    fill(CGRect(x: x, y: y, width: max(56, w * frac), height: 56), c, radius: 28)
    if flash > 0 { fill(CGRect(x: x - 8, y: y - 8, width: w + 16, height: 72), rgb(WHITE, 0.5 * flash), radius: 36) }
}
/// 彩纸
func confetti(_ t: Double, t0: Double, cx: Double, cy: Double, n: Int = 40, seed: Int = 0) {
    let dt = t - t0
    guard dt > 0, dt < 1.6 else { return }
    let cols: [UInt32] = [YELLOW, RED, GREEN, 0x5b8def, 0xff7ad9, WHITE]
    for i in 0..<n {
        let a = hash(i + seed) * 2 * .pi, v = 700 + hash(i * 7 + seed) * 900
        let x = cx + cos(a) * v * dt, y = cy + sin(a) * v * dt + 1400 * dt * dt
        ctx.saveGState()
        ctx.setAlpha(1 - prog(dt, 1.0, 1.6))
        ctx.translateBy(x: x, y: y)
        ctx.rotate(by: dt * 10 * (hash(i + 3) - 0.5) * 4)
        fill(CGRect(x: -12, y: -6, width: 24, height: 12), rgb(cols[i % cols.count]), radius: 3)
        ctx.restoreGState()
    }
}

// MARK: - 时间轴（拍）

let HOOK = 0.0, HELP = b(10), SUMMON = b(16), CHASE = b(29), CLEAN = b(42), SAFE = b(58), MONTAGE = b(66), END = b(72)
let CUTS = [HELP, SUMMON, CHASE, CLEAN, SAFE, MONTAGE, END]

// 开头：上传数字狂飙
func uploadedMB(_ t: Double) -> Double { 1840 * easeIn(prog(t, b(2), b(8.5))) }

// 0：钩子
func sceneHook(_ t: Double) {
    let alarm = Int(t / BEAT) % 2 == 0
    bg(alarm ? 0x1a0505 : 0x0d0d0d)
    rays(W / 2, 900, RED, 0.10 + (alarm ? 0.06 : 0), spin: t * 0.3)
    glow(W / 2, 900, 900, RED, alarm ? 0.35 : 0.18)
    // 截图像子弹一样往上飞（在字后面）
    for i in 0..<14 {
        let st = b(2) + Double(i) * b(0.5)
        let p = prog(t, st, st + 0.5)
        guard p > 0, p < 1 else { continue }
        let x = i % 2 == 0 ? 60 + hash(i) * 130 : 890 + hash(i) * 130   // 只走左右两边，不挡中间的字
        card(x, lerp(H + 100, -200, easeIn(p)), 170, 126, hue: i, alpha: 0.85, rot: (hash(i * 3) - 0.5) * 0.6)
    }
    slam("Codex re-uploads", t, t0: 0, y: 420, size: 96, color: WHITE, rot: -0.04)
    slam("your old screenshots", t, t0: b(1.5), y: 570, size: 84, color: WHITE, rot: 0.03)
    slam("EVERY. SINGLE.", t, t0: b(3), y: 760, size: 120, color: YELLOW, rot: -0.03)
    slam("MESSAGE.", t, t0: b(4.5), y: 910, size: 140, color: YELLOW, rot: 0.04)
    let mb = uploadedMB(t)
    let a = prog(t, b(2), b(2.3))
    plain("UPLOADED", W / 2, 1150, size: 48, color: rgb(0xffb3ab), alpha: a)
    pop(mb < 1000 ? String(format: "%.0f MB", mb) : String(format: "%.2f GB", mb / 1000), W / 2, 1280, size: 150,
        color: RED, stroke: WHITE, alpha: a, scale: 1 + 0.06 * impulse((t - b(2)).truncatingRemainder(dividingBy: BEAT)), mono: true)
    plain("VPN QUOTA", 140, 1440, size: 40, color: rgb(WHITE), alpha: a, align: 0)
    bar(140, 1480, 800, frac: 1 - 0.9 * mb / 1840, flash: alarm && t > b(6) ? 1 : 0)
}

// 1：别慌，小黑来了
func sceneHelp(_ t: Double) {
    bg(YELLOW)
    rays(W / 2, 1150, WHITE, 0.35, spin: t * 0.5)
    slam("Don't panic!", t, t0: HELP, y: 420, size: 130, color: WHITE, rot: -0.04)
    slam("Meet Xiaohei", t, t0: HELP + b(1.5), y: 600, size: 110, color: INK, rot: 0.03, stroke: WHITE)
    let rise = spring(t - HELP - b(0.5), freq: 2.0, damp: 0.42)
    groundShadow(W / 2, 1500, 520, 0.35 * clamp01(rise))
    dog(pingpong(STAND, t, fps: 15), cx: W / 2, bottom: lerp(H + 500, 1500, rise), height: 760)
    slam("Woof!", t, t0: HELP + b(3), x: 820, y: 900, size: 110, color: RED, rot: 0.2, stroke: WHITE)
}

// 2：右下角晃鼠标 → 淀粉肠 → 小黑钻出来
let SAUS_POP = SUMMON + b(7)
func sceneSummon(_ t: Double) {
    // 竖屏里放大的桌面右下角
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(0x2f5d8c), rgb(0x8db2da)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: H), options: [])
    glow(900, 1500, 900, 0xffd9a0, 0.25)
    fill(CGRect(x: -40, y: H - 260, width: 760, height: 130), rgb(WHITE, 0.32), radius: 34)
    let icons: [UInt32] = [0x5b8def, 0xf0a04b, 0x4cb782, 0xe0607e, 0x9b6ef3, 0x2ab0c5]
    for (i, c) in icons.enumerated() { fill(CGRect(x: 0 + Double(i) * 116, y: H - 244, width: 96, height: 96), rgb(c), radius: 22) }

    slam("Shake your mouse", t, t0: SUMMON, t1: SAUS_POP - 0.05, y: 420, size: 96, color: WHITE, rot: -0.03)
    slam("in the corner!", t, t0: SUMMON + b(1.5), t1: SAUS_POP - 0.05, y: 580, size: 110, color: YELLOW, rot: 0.04)
    slam("Poof! Sausage!", t, t0: SAUS_POP, y: 480, size: 120, color: YELLOW, rot: -0.04)

    let base = (x: 800.0, y: 1150.0)
    func cx(_ tt: Double) -> Double {
        let amp = tt > SUMMON + b(2) && tt < SAUS_POP ? 170.0 : 0
        return base.x + sin((tt - SUMMON) * 2 * .pi / BEAT) * amp   // 一拍一个来回
    }
    if t < SAUS_POP {
        for k in 1...6 { arrow(cx(t - Double(k) * 0.018), base.y, alpha: 0.18 * Double(7 - k) / 6) }
        arrow(cx(t), base.y)
    } else {
        let s = spring(t - SAUS_POP, freq: 3, damp: 0.4)
        rays(base.x, base.y, YELLOW, 0.25 * (1 - prog(t, SAUS_POP, SAUS_POP + 0.6)), spin: t)
        sausage(base.x, base.y, height: 260, scale: s, rot: sin(t * 6) * 0.08)
        confetti(t, t0: SAUS_POP, cx: base.x, cy: base.y, n: 30, seed: 5)
    }
    if t > SAUS_POP + b(1.5) {
        let rise = spring(t - SAUS_POP - b(1.5), freq: 2.2, damp: 0.42)
        groundShadow(330, H - 300, 360, 0.3 * clamp01(rise))
        dog(pingpong(STAND, t, fps: 15), cx: 330, bottom: lerp(H + 600, H - 300, rise), height: 560)
        slam("Woof! Sausage!", t, t0: SAUS_POP + b(2.5), x: 400, y: 1010, size: 70, color: WHITE, rot: -0.06)
    }
}

// 3：一蹦一蹦地追，追上吃掉
let EAT = CHASE + b(11)
func sausagePath(_ t: Double) -> (Double, Double) {
    let u = min(t, EAT - b(1)) - CHASE
    return (W / 2 + 330 * sin(u * 1.7), 1150 + 200 * sin(u * 1.1 + 1.2))
}
func chaseState(_ t: Double) -> (x: Double, y: Double, left: Bool) {
    var x = 330.0, y = H - 300, left = false
    var tt = CHASE
    let dt = 1.0 / 120
    while tt < t {
        let (sx, sy) = sausagePath(tt)
        let tx = sx + (left ? 120 : -120), ty = sy + 380
        let dx = tx - x, dy = ty - y, d = hypot(dx, dy)
        let step = min(d, 700.0 * dt)
        if d > 1 { x += dx / d * step; y += dy / d * step; if abs(dx) > 4 { left = dx < 0 } }
        tt += dt
    }
    return (x, y, left)
}
func sceneChase(_ t: Double) {
    bg(BLUE)
    rays(W / 2, 1000, WHITE, 0.10, spin: -t * 0.8, n: 24)
    // 速度线
    for i in 0..<10 {
        let y = 300 + hash(i + 40) * 1300, len = 200 + hash(i + 50) * 300
        let x = (W + len) - ((t * 2400 + hash(i + 60) * 2000).truncatingRemainder(dividingBy: W + 2 * len))
        fill(CGRect(x: x, y: y, width: len, height: 8), rgb(WHITE, 0.35), radius: 4)
    }
    slam("GO GO GO!", t, t0: CHASE, t1: EAT - 0.05, y: 400, size: 150, color: YELLOW, rot: -0.06)
    let (sx, sy) = sausagePath(t)
    let s = chaseState(t)
    if t < EAT {
        let hop = abs(sin((t - CHASE) * .pi / (BEAT / 2))) * 40
        groundShadow(s.x, s.y, 300 - hop * 2, 0.25)
        dog(pingpong(BEG, t, fps: 20), cx: s.x, bottom: s.y - hop, height: 470, flip: !s.left)
        let e = easeIn(prog(t, EAT - b(1), EAT))
        sausage(lerp(sx, s.x, e), lerp(sy, s.y - 360, e), height: 220, scale: 1 - e * 0.9, rot: sin(t * 6) * 0.1)
    } else {
        rays(s.x, s.y - 250, YELLOW, 0.35 * (1 - prog(t, EAT, EAT + 1)), spin: t)
        let jump = sin(clamp01((t - EAT) / 0.45) * .pi) * 120
        let sq = spring(t - EAT, freq: 3, damp: 0.3)
        groundShadow(s.x, s.y, 320, 0.25)
        dog(pingpong(STAND, t, fps: 15), cx: s.x, bottom: s.y - jump, height: 480, sx: 2 - sq, sy: sq)
        slam("CHOMP!", t, t0: EAT, y: 400, size: 180, color: YELLOW, rot: 0.05)
        confetti(t, t0: EAT, cx: s.x, cy: s.y - 300, n: 50, seed: 11)
    }
}

// 4：点一下，截图全炸掉，流量暴跌
let CLICK = CLEAN + b(3), POPS = (0..<12).map { CLEAN + b(5) + Double($0) * b(0.5) }, STAMP = CLEAN + b(12.5)
func sceneClean(_ t: Double) {
    bg(0xfff3d6)
    slam("One click...", t, t0: CLEAN, t1: CLICK + b(1.5), y: 360, size: 130, color: WHITE, rot: -0.04)
    slam("Old screenshots", t, t0: CLICK + b(1.5), y: 360, size: 94, color: WHITE, rot: 0.03)
    slam("GONE!", t, t0: CLICK + b(3), y: 530, size: 160, color: RED, rot: -0.03)
    // 截图墙
    for k in 0..<12 {
        let col = Double(k % 3), row = Double(k / 3)
        let cx = 230 + col * 310, cy = 760 + row * 230
        let a = spring(t - CLEAN - Double(k) * 0.03, freq: 2.6, damp: 0.55)
        let p = prog(t, POPS[k] - 0.02, POPS[k] + 0.12)
        if p < 1 { card(cx, cy, 260, 190, hue: k, alpha: clamp01(a * 2), scale: a * (1 + p * 0.3), rot: (hash(k) - 0.5) * 0.12) }
        if t > POPS[k] {
            confetti(t, t0: POPS[k], cx: cx, cy: cy, n: 10, seed: k * 13)
            fill(CGRect(x: cx - 9, y: cy - 9, width: 18, height: 18), rgb(0xb9b6ad, prog(t, POPS[k], POPS[k] + 0.2)), radius: 4)
        }
    }
    // 点击
    let ax = lerp(1000, 560, easeOut(prog(t, CLEAN + b(1), CLICK))), ay = lerp(1700, 1000, easeOut(prog(t, CLEAN + b(1), CLICK)))
    arrow(ax, ay, alpha: 1 - prog(t, CLICK + b(1.5), CLICK + b(2)))
    if t > CLICK && t < CLICK + 0.5 {
        let p = easeOut(prog(t, CLICK, CLICK + 0.5))
        ctx.saveGState()
        ctx.setStrokeColor(rgb(RED, 1 - p)); ctx.setLineWidth(10)
        let r = 30 + p * 130
        ctx.strokeEllipse(in: CGRect(x: ax - r, y: ay - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
    }
    // 流量暴跌
    let q = easeInOut(prog(t, POPS[0], POPS[11] + 0.1))
    let mb = lerp(1840, 0.2, q)
    let s = mb >= 1000 ? String(format: "%.2f GB", mb / 1000) : (mb < 1 ? String(format: "%.1f MB", mb) : String(format: "%.0f MB", mb))
    plain("UPLOAD PER MESSAGE", W / 2, 1530, size: 44, color: rgb(0x6b6b73))
    pop(s, W / 2, 1640, size: 130, color: q < 1 ? RED : GREEN, stroke: INK, alpha: 1, mono: true)
    // 盖章
    if t > STAMP {
        let p = spring(t - STAMP, freq: 3.5, damp: 0.5)
        ctx.saveGState()
        ctx.translateBy(x: W / 2, y: 1090)
        ctx.rotate(by: -0.18)
        ctx.scaleBy(x: lerp(2.5, 1, p), y: lerp(2.5, 1, p))
        ctx.setAlpha(clamp01((t - STAMP) / 0.06))
        ctx.setStrokeColor(rgb(GREEN)); ctx.setLineWidth(18)
        ctx.addPath(CGPath(roundedRect: CGRect(x: -330, y: -140, width: 660, height: 280), cornerWidth: 40, cornerHeight: 40, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
        pop("CLEAN!", W / 2, 1090, size: 150, color: GREEN, stroke: WHITE, scale: lerp(2.5, 1, p), rot: -0.18)
    }
}

// 5：聊天记录一条不丢
let CHECKS = (0..<5).map { SAFE + b(2) + Double($0) * b(1) }
func sceneSafe(_ t: Double) {
    bg(0x123d2a)
    rays(W / 2, 1000, GREEN, 0.12, spin: t * 0.4)
    slam("Chat history", t, t0: SAFE, y: 380, size: 120, color: WHITE, rot: -0.03)
    slam("100% intact ✓", t, t0: SAFE + b(1.5), y: 550, size: 120, color: GREEN, rot: 0.03, stroke: WHITE)
    let titles = ["Build a mini game", "App review rejected", "Teach me music", "Fix the login bug", "Weekly report"]
    for (i, s) in titles.enumerated() {
        let y = 760 + Double(i) * 170
        let a = spring(t - SAFE - Double(i) * 0.05, freq: 2.4, damp: 0.6)
        let r = CGRect(x: 120 + (1 - a) * 800, y: y - 65, width: 840, height: 130)
        fill(r, rgb(WHITE), radius: 30, shadow: 16)
        plain(s, r.minX + 50, y, size: 52, color: rgb(INK), align: 0)
        if t > CHECKS[i] {
            let p = spring(t - CHECKS[i], freq: 3, damp: 0.45)
            fill(CGRect(x: r.maxX - 110 - 40 * p, y: y - 40 * p, width: 80 * p, height: 80 * p), rgb(GREEN), radius: 40 * p)
            plain("✓", r.maxX - 110, y, size: 56 * p, color: rgb(WHITE))
        }
    }
}

// 6：平时的小黑，三连快切
func sceneMontage(_ t: Double) {
    let k = min(2, Int((t - MONTAGE) / b(2)))
    let local = t - MONTAGE - Double(k) * b(2)
    bg([0xff7ad9, 0x5b8def, 0x2a2350][k])
    rays(W / 2, 1000, WHITE, 0.15, spin: t * 0.6)
    let s = spring(local, freq: 3.5, damp: 0.5)
    switch k {
    case 0:
        dog(pingpong(LOOK, t - MONTAGE, fps: 14), cx: W / 2, bottom: 1500, height: 900 * s)
        pop("Looks around", W / 2, 420, size: 120, color: WHITE, scale: s, rot: -0.04)
    case 1:
        dog(BELLY, cx: W / 2, bottom: 1400, height: 620 * s, rot: sin(t * 20) * 0.05)
        pop("Belly rubs!", W / 2, 420, size: 130, color: YELLOW, scale: s, rot: 0.04)
    default:
        dog(SLEEP, cx: W / 2, bottom: 1400, height: 620 * s)
        pop("Naps a lot", W / 2, 420, size: 130, color: WHITE, scale: s, rot: -0.03)
        pop("Zzz", 860, 820, size: 110, color: 0xa9b8ff, scale: s, rot: 0.15)
    }
}

// 7：结尾
func sceneEnd(_ t: Double) {
    bg(YELLOW)
    rays(W / 2, 900, WHITE, 0.4, spin: t * 0.4)
    let rise = spring(t - END, freq: 2.2, damp: 0.45)
    groundShadow(W / 2, 1130, 460, 0.3 * clamp01(rise))
    dog(pingpong(STAND, t, fps: 15), cx: W / 2, bottom: lerp(H + 500, 1130, rise), height: 680)
    slam("Xiaohei", t, t0: END + b(0.5), y: 330, size: 190, color: WHITE, rot: -0.04)
    slam("Saves your Codex bandwidth", t, t0: END + b(1.5), y: 510, size: 66, color: INK, rot: 0.02, stroke: WHITE)
    let u = spring(t - END - b(2.5), freq: 2.5, damp: 0.6)
    if u > 0.01 {
        let r = CGRect(x: 90, y: 1250 + (1 - u) * 80, width: 900, height: 230)
        fill(r, rgb(INK), radius: 40)
        plain("Free & open source on GitHub", W / 2, r.minY + 70, size: 48, color: rgb(YELLOW), alpha: clamp01(u))
        plain("zio005792-blip/CodexDog", W / 2, r.minY + 160, size: 50, color: rgb(WHITE), alpha: clamp01(u), mono: true)
    }
    slam("One command to install", t, t0: END + b(4), y: 1600, size: 68, color: WHITE, rot: -0.02)
}

func scene(_ t: Double) {
    switch t {
    case ..<HELP: sceneHook(t)
    case ..<SUMMON: sceneHelp(t)
    case ..<CHASE: sceneSummon(t)
    case ..<CLEAN: sceneChase(t)
    case ..<SAFE: sceneClean(t)
    case ..<MONTAGE: sceneSafe(t)
    case ..<END: sceneMontage(t)
    default: sceneEnd(t)
    }
}

// MARK: - 镜头和转场

/// 每次重音都猛推一下镜头；开头警报时画面抖
func camera(_ t: Double) -> (Double, Double, Double) {
    var s = 1.0
    let hits = [0, b(1.5), b(3), b(4.5), HELP, HELP + b(0.5), SAUS_POP, EAT, CLICK, STAMP, SAFE, MONTAGE, MONTAGE + b(2), MONTAGE + b(4), END + b(0.5)]
    for h in hits { s += 0.07 * impulse(t - h) }
    var dx = 0.0, dy = 0.0
    if t < HELP {
        let k = t * 60
        dx = (hash(Int(k)) - 0.5) * 14 * prog(t, b(2), b(6))
        dy = (hash(Int(k) + 99) - 0.5) * 14 * prog(t, b(2), b(6))
    }
    if t > EAT && t < EAT + 0.4 { dx += sin(t * 120) * 18 * (1 - prog(t, EAT, EAT + 0.4)) }
    return (s, W / 2 + dx, H / 2 + dy)
}

/// 转场：上一个场景整体往上滑走，新场景从下面顶上来，中间夹一道白闪
func render(_ t: Double) {
    let (s, cx, cy) = camera(t)
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: -W / 2, y: -H / 2)
    if let c = CUTS.first(where: { t >= $0 && t < $0 + 0.18 }) {
        let p = easeOut(prog(t, c, c + 0.18))
        ctx.saveGState(); ctx.translateBy(x: 0, y: -p * H); scene(c - 0.001); ctx.restoreGState()
        ctx.saveGState(); ctx.translateBy(x: 0, y: (1 - p) * H); scene(t); ctx.restoreGState()
    } else {
        scene(t)
    }
    ctx.restoreGState()
    for c in CUTS where t >= c && t < c + 0.1 {
        fill(CGRect(x: 0, y: 0, width: W, height: H), rgb(WHITE, 0.5 * (1 - (t - c) / 0.1)))
    }
}

func finish(_ t: Double) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(0, 0), rgb(0, 0.25)] as CFArray, locations: [0.6, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: W / 2, y: H / 2), startRadius: 0,
                           endCenter: CGPoint(x: W / 2, y: H / 2), endRadius: hypot(W, H) / 2, options: [.drawsAfterEndLocation])
    let fade = prog(t, DUR - 0.35, DUR)
    if fade > 0 { fill(CGRect(x: 0, y: 0, width: W, height: H), rgb(0x000000, fade)) }
}

// MARK: - 声音（120 BPM，电子舞曲风）

let SR = 48000.0
let NS = Int(DUR * SR)
var music = [Float](repeating: 0, count: NS), sfx = music

func mtof(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
var rng: UInt64 = 7
func noise() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(Int64(bitPattern: rng >> 1) % 2_000_000) / 1_000_000 - 1 }
func add(_ buf: inout [Float], _ t: Double, _ len: Double, gain: Double, _ f: (Double) -> Double) {
    let s0 = Int(t * SR), n = Int(len * SR)
    for i in 0..<n where s0 + i >= 0 && s0 + i < NS { buf[s0 + i] += Float(f(Double(i) / SR) * gain) }
}
func saw(_ ph: Double) -> Double { 2 * (ph - floor(ph + 0.5)) }
func sq(_ ph: Double) -> Double { ph - floor(ph) < 0.5 ? 1 : -1 }

func kick(_ t: Double, _ g: Double, _ b: inout [Float]) {
    add(&b, t, 0.3, gain: g) { x in exp(-x * 10) * sin(2 * .pi * (48 * x + 140 / 30 * (1 - exp(-x * 30)))) }
}
func clap(_ t: Double, _ g: Double, _ b: inout [Float]) {
    var prev = 0.0
    add(&b, t, 0.22, gain: g) { x in
        let n = noise(); let hp = n - prev; prev = n
        return hp * (exp(-x * 40) + 0.7 * (x > 0.015 ? exp(-(x - 0.015) * 22) : 0))
    }
}
func hat(_ t: Double, _ g: Double, open: Bool, _ b: inout [Float]) {
    var prev = 0.0
    add(&b, t, open ? 0.18 : 0.05, gain: g) { x in let n = noise(); let hp = n - prev; prev = n; return hp * exp(-x * (open ? 18 : 90)) }
}
func bassNote(_ t: Double, _ note: Double, _ len: Double, _ g: Double, _ b: inout [Float]) {
    let f = mtof(note)
    var lp = 0.0
    add(&b, t, len, gain: g) { x in
        let raw = saw(f * x) * 0.7 + sin(2 * .pi * f * x)
        let cut = 0.05 + 0.25 * exp(-x * 14)
        lp += (raw - lp) * cut
        return lp * min(1, x / 0.004) * (1 - prog(x, len - 0.02, len))
    }
}
func stab(_ t: Double, _ notes: [Double], _ len: Double, _ g: Double, _ b: inout [Float]) {
    for n in notes {
        let f = mtof(n)
        var lp = 0.0
        add(&b, t, len, gain: g / Double(notes.count)) { x in
            let raw = saw(f * x) + saw(f * 1.006 * x) * 0.8 + saw(f * 0.994 * x) * 0.8
            lp += (raw - lp) * (0.08 + 0.3 * exp(-x * 8))
            return lp * min(1, x / 0.005) * exp(-x * 3.5) * (1 - prog(x, len - 0.03, len))
        }
    }
}
func lead(_ t: Double, _ note: Double, _ len: Double, _ g: Double, _ b: inout [Float]) {
    let f = mtof(note)
    add(&b, t, len + 0.15, gain: g) { x in
        let vib = 1 + 0.004 * sin(2 * .pi * 6 * x) * clamp01(x / 0.2)
        return (sq(f * vib * x) * 0.5 + sin(2 * .pi * f * vib * x)) * min(1, x / 0.005) * exp(-x * 2.5) * (1 - prog(x, len, len + 0.15))
    }
}
func riser(_ t: Double, _ len: Double, _ g: Double, _ b: inout [Float]) {
    var lp = 0.0, ph = 0.0
    add(&b, t, len, gain: g) { x in
        let p = x / len
        lp += (noise() - lp) * (0.02 + 0.5 * p * p)
        ph += 2 * .pi * (200 + 1400 * p * p) / SR
        return (lp * 1.4 + sin(ph) * 0.4) * p * p
    }
}
func impact(_ t: Double, _ g: Double, _ b: inout [Float]) {
    var lp = 0.0
    add(&b, t, 1.2, gain: g) { x in
        lp += (noise() - lp) * 0.08
        return sin(2 * .pi * (40 + 80 * exp(-x * 12)) * x) * exp(-x * 3) + lp * exp(-x * 5) * 0.8
    }
}

// 音效
func sPop(_ t: Double, _ g: Double = 0.35, pitch: Double = 1) {
    add(&sfx, t, 0.12, gain: g) { x in sin(2 * .pi * (420 + 800 * exp(-x * 40)) * pitch * x) * exp(-x * 26) }
}
func sWhoosh(_ t: Double, _ len: Double = 0.3, _ g: Double = 0.3) {
    var lp = 0.0
    add(&sfx, t, len, gain: g) { x in let p = x / len; lp += (noise() - lp) * (0.03 + 0.3 * sin(p * .pi)); return lp * sin(p * .pi) * 2.2 }
}
func sBoing(_ t: Double, _ g: Double = 0.3) {
    add(&sfx, t, 0.45, gain: g) { x in sin(2 * .pi * (180 + 480 * (1 - exp(-x * 9)) + 30 * sin(x * 2 * .pi * 15)) * x) * exp(-x * 6) * min(1, x / 0.01) }
}
func sAlarm(_ t: Double, _ g: Double = 0.12) {
    add(&sfx, t, 0.18, gain: g) { x in sq(1320 * x) * 0.5 * (1 - prog(x, 0.15, 0.18)) }
}
func sNom(_ t: Double) {
    for k in 0..<2 {
        add(&sfx, t + Double(k) * 0.13, 0.11, gain: 0.4) { x in
            let f = 230 - 70 * x / 0.11
            return (0.5 * sq(f * x) + sin(2 * .pi * f * x)) * sin(.pi * min(1, x / 0.11)) * 0.6
        }
    }
}
func sDing(_ t: Double, _ note: Double, _ g: Double = 0.25) {
    let f = mtof(note)
    add(&sfx, t, 1.0, gain: g) { x in (sin(2 * .pi * f * x + 1.2 * sin(2 * .pi * f * 3.5 * x) * exp(-x * 6))) * exp(-x * 4) * min(1, x / 0.002) }
}
func sClick(_ t: Double) {
    add(&sfx, t, 0.03, gain: 0.4) { x in noise() * exp(-x * 220) }
    add(&sfx, t, 0.05, gain: 0.3) { x in sin(2 * .pi * 1800 * x) * exp(-x * 140) }
}
func sScratch(_ t: Double) {
    var lp = 0.0
    add(&sfx, t, 0.3, gain: 0.35) { x in
        let rate = sin(x / 0.3 * .pi * 2) * 0.5 + 0.5
        lp += (noise() - lp) * (0.05 + 0.3 * rate)
        return lp * 2 * sin(.pi * x / 0.3)
    }
}
func sStamp(_ t: Double) {
    add(&sfx, t, 0.25, gain: 0.55) { x in sin(2 * .pi * (70 + 90 * exp(-x * 25)) * x) * exp(-x * 14) }
    add(&sfx, t, 0.06, gain: 0.3) { x in noise() * exp(-x * 60) }
}

func compose() {
    // F – G – Em – Am，四拍一个和弦（一小节 2 秒）
    let chords: [(Double, [Double])] = [(41, [65, 69, 72, 76]), (43, [67, 71, 74, 79]), (40, [64, 67, 71, 76]), (45, [69, 72, 76, 81])]
    let melody: [[(Double, Double, Double)]] = [   // (拍, 音, 长度拍)
        [(0, 81, 0.5), (0.5, 79, 0.5), (1, 77, 0.5), (1.5, 76, 0.5), (2, 77, 1), (3, 72, 0.5), (3.5, 74, 0.5)],
        [(0, 79, 0.5), (0.5, 76, 0.5), (1, 74, 0.5), (1.5, 76, 0.5), (2, 79, 1), (3, 83, 1)],
        [(0, 79, 0.5), (0.5, 76, 0.5), (1, 71, 0.5), (1.5, 72, 0.5), (2, 76, 0.5), (2.5, 79, 0.5), (3, 76, 1)],
        [(0, 81, 0.75), (0.75, 84, 0.75), (1.5, 81, 0.5), (2, 79, 0.5), (2.5, 76, 0.5), (3, 81, 1)],
    ]
    var drums = [Float](repeating: 0, count: NS), bass = drums, syn = drums, top = drums
    let bars = Int(ceil(DUR / b(4)))
    for bar in 0..<bars {
        let t0 = b(4) * Double(bar)
        let (root, notes) = chords[bar % 4]
        // HELP 前一拍刹车（只留 riser），之后全力
        let drop = t0 >= HELP - 0.01
        for k in 0..<4 {
            let tb = t0 + b(Double(k))
            if tb >= DUR - 0.4 { break }
            let brk = tb >= HELP - b(1) && tb < HELP     // 刹车那一拍
            if !brk {
                kick(tb, drop ? 0.75 : 0.6, &drums)
                if k % 2 == 1 { clap(tb, 0.3, &drums) }
                hat(tb + b(0.5), drop ? 0.12 : 0.08, open: true, &drums)
                hat(tb + b(0.25), 0.04, open: false, &drums); hat(tb + b(0.75), 0.04, open: false, &drums)
                for e in 0..<2 { bassNote(tb + b(0.5 * Double(e)), root + (e == 1 ? 12 : 0), b(0.45), 0.32, &bass) }
                if drop { stab(tb + b(0.5), notes, b(0.4), 0.16, &syn) }
            }
        }
        if drop && t0 < END + b(3) {
            for (bt, n, l) in melody[bar % 4] { lead(t0 + b(bt), n, b(l) * 0.9, 0.09, &top) }
        }
    }
    // 结尾大和弦
    stab(END + b(4), [65, 69, 72, 77, 81], 2.0, 0.3, &syn)
    bassNote(END + b(4), 29, 1.6, 0.4, &bass)
    riser(HELP - b(3), b(3), 0.22, &top)
    riser(CLEAN - b(2), b(2), 0.12, &top)
    impact(HELP, 0.5, &drums)
    impact(END + b(4), 0.45, &drums)
    // 侧链：每个底鼓把合成器和贝斯压一下，做出"呼吸"感
    for i in 0..<NS {
        let x = (Double(i) / SR).truncatingRemainder(dividingBy: BEAT)
        let duck = Float(0.35 + 0.65 * clamp01(x / 0.18))
        music[i] = drums[i] + (bass[i] + syn[i]) * duck + top[i]
    }

    // 音效
    for c in CUTS { sWhoosh(c - 0.2, 0.3, 0.3) }
    for k in 0..<4 { sPop(b(Double(k) * 1.5), 0.4, pitch: 0.7 + Double(k) * 0.15) }
    for k in 4..<20 { sAlarm(b(Double(k) * 0.5), 0.07) }
    sScratch(HELP - b(1))
    sBoing(HELP + b(0.5), 0.4)
    sPop(HELP + b(3), 0.45, pitch: 1.4)
    for k in 0..<10 { sWhoosh(SUMMON + b(2) + Double(k) * b(0.5), 0.15, 0.12) }
    sPop(SAUS_POP, 0.55, pitch: 1.3)
    sBoing(SAUS_POP + b(1.5), 0.35)
    var h = CHASE + b(0.5)
    while h < EAT { add(&sfx, h, 0.08, gain: 0.18) { x in sin(2 * .pi * (95 + 70 * exp(-x * 50)) * x) * exp(-x * 40) }; h += b(0.5) }
    sNom(EAT)
    sPop(EAT + 0.12, 0.45, pitch: 1.6)
    sClick(CLICK)
    for (k, p) in POPS.enumerated() { sPop(p, 0.3, pitch: 0.8 + Double(k) * 0.06) }
    sStamp(STAMP)
    sDing(STAMP + 0.02, 91, 0.25)
    for (k, c) in CHECKS.enumerated() { sDing(c, [84, 86, 88, 91, 93][k], 0.2) }
    for k in 0..<3 { sPop(MONTAGE + b(Double(k) * 2), 0.45, pitch: 1 + Double(k) * 0.2) }
    sBoing(END, 0.3)
}

func mixdown() -> ([Float], [Float]) {
    var L = [Float](repeating: 0, count: NS), R = L
    var peak: Float = 0
    for i in 0..<NS {
        let t = Double(i) / SR
        let fade = Float(1 - prog(t, DUR - 0.5, DUR))
        let v = (music[i] * 0.6 + sfx[i] * 0.85) * fade
        // 一点立体声：音效稍微偏一边
        L[i] = v + sfx[i] * 0.05; R[i] = v - sfx[i] * 0.05
        peak = max(peak, abs(L[i]), abs(R[i]))
    }
    let g = 1.2 / max(peak, 0.01)   // 推响一点再软削波，短视频要响
    for i in 0..<NS {
        L[i] = Float(tanh(Double(L[i] * g)) / tanh(1.2)) * 0.9
        R[i] = Float(tanh(Double(R[i] * g)) / tanh(1.2)) * 0.9
    }
    return (L, R)
}

func writeWAV(_ L: [Float], _ R: [Float], _ url: URL) {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: SR, channels: 2)!
    let f = try! AVAudioFile(forWriting: url, settings: fmt.settings)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(NS))!
    buf.frameLength = AVAudioFrameCount(NS)
    for i in 0..<NS { buf.floatChannelData![0][i] = L[i]; buf.floatChannelData![1][i] = R[i] }
    try! f.write(from: buf)
}

// MARK: - 输出

func makeContext(_ data: UnsafeMutableRawPointer?, bytesPerRow: Int) -> CGContext {
    let c = CGContext(data: data, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    c.translateBy(x: 0, y: H)
    c.scaleBy(x: 1, y: -1)
    c.interpolationQuality = .high
    return c
}

func renderFrame(_ f: Int, into target: CGContext) {
    let t = Double(f) / FPS
    let sub = makeContext(nil, bytesPerRow: Int(W) * 4)
    for k in 0..<SUB {
        ctx = sub
        ctx.saveGState()
        render(t + Double(k) / Double(SUB) * 0.5 / FPS)
        ctx.restoreGState()
        let img = sub.makeImage()!
        target.saveGState()
        target.setAlpha(1 / Double(k + 1))
        target.translateBy(x: 0, y: H); target.scaleBy(x: 1, y: -1)
        target.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        target.restoreGState()
    }
    ctx = target
    finish(t)
}

let args = CommandLine.arguments
if args.count > 3 && args[1] == "--still" {
    for s in args[2].split(separator: ",") {
        let t = Double(s)!
        let c = makeContext(nil, bytesPerRow: Int(W) * 4)
        renderFrame(Int(t * FPS), into: c)
        let url = URL(fileURLWithPath: args[3]).appendingPathComponent(String(format: "s_%05.2f.png", t))
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, c.makeImage()!, nil)
        CGImageDestinationFinalize(d)
    }
    exit(0)
}

let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "xiaohei_short_en.mp4")
let tmpDir = FileManager.default.temporaryDirectory
let silent = tmpDir.appendingPathComponent("xiaohei_short_en_silent.mp4")
let wav = tmpDir.appendingPathComponent("xiaohei_short_en.wav"), m4a = tmpDir.appendingPathComponent("xiaohei_short_en.m4a")

print("合成声音…")
compose()
let (L, R) = mixdown()
writeWAV(L, R, wav)
if args.count > 2 && args[2] == "--audio-only" { print(wav.path); exit(0) }
let skipVideo = args.count > 2 && args[2] == "--reuse-video"   // 画面没改时直接用上次渲染好的

let sem = DispatchSemaphore(value: 0)
print("渲染画面…")
if !skipVideo {
try? FileManager.default.removeItem(at: silent)
let writer = try! AVAssetWriter(outputURL: silent, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 9_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H),
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
let total = Int(DUR * FPS)
for f in 0..<total {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    renderFrame(f, into: makeContext(CVPixelBufferGetBaseAddress(pb!), bytesPerRow: CVPixelBufferGetBytesPerRow(pb!)))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(FPS)))
    if f % 300 == 0 { print("  \(f)/\(total)") }
}
input.markAsFinished()
writer.finishWriting { sem.signal() }
sem.wait()
}

print("合成音轨…")
try? FileManager.default.removeItem(at: m4a)
let aac = AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A)!
aac.outputURL = m4a
aac.outputFileType = .m4a
aac.exportAsynchronously { sem.signal() }
sem.wait()
let comp = AVMutableComposition()
// 按两条轨实际的长度拼（AAC 编码后长度会差几毫秒）
let vAsset = AVURLAsset(url: silent), aAsset = AVURLAsset(url: m4a)   // 素材对象要留着，轨道才有效
let vTrack = vAsset.tracks(withMediaType: .video)[0]
let aTrack = aAsset.tracks(withMediaType: .audio)[0]
let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(vTrack.timeRange.duration, aTrack.timeRange.duration))
try! comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    .insertTimeRange(range, of: vTrack, at: .zero)
try! comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    .insertTimeRange(range, of: aTrack, at: .zero)
try? FileManager.default.removeItem(at: out)
let exporter = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
exporter.outputURL = out
exporter.outputFileType = .mp4
exporter.exportAsynchronously { sem.signal() }
sem.wait()
print(exporter.status == .completed ? "完成 \(out.path)" : "失败 \(String(describing: exporter.error))")
