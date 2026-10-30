// 小黑介绍视频 v2：画面逐帧画出来，配乐和音效用代码合成，最后合成 MP4（字幕不配音）
// 用法：swiftc -O intro.swift -o intro && ./intro xiaohei_intro.mp4
//       ./intro --still 5.0,12.5 outdir   只导出这几秒的 PNG 预览
// 素材来自 CodexDog 第一次启动时抠好的图：~/Library/Application Support/CodexDog
// 所有动作都卡在 120 BPM 的节拍上（一拍 0.5 秒，一小节 2 秒）
import AppKit
import AVFoundation
import CoreText

let W = 1920.0, H = 1080.0, FPS = 60.0, SUB = 3, DUR = 49.0
let BEAT = 0.5
let SUP = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexDog")

// MARK: - 字幕（开始时间, 文字）；每句显示多久按系统语音念一遍的时长来定，但不放出声音

let VO: [(Double, String)] = [
    (0.8, "这是小黑，一只帮 Codex 省流量的桌面小狗。"),
    (5.3, "你在 Codex 里贴过的每一张截图，"),
    (8.2, "之后每发一句话，都会被重新上传一遍。"),
    (12.1, "流量和 VPN 额度，就这样被悄悄烧光。"),
    (17.3, "想叫它出来？在屏幕右下角，晃晃鼠标。"),
    (22.3, "鼠标变成淀粉肠，它就站起来，一蹦一蹦地追。"),
    (28.4, "点它一下，会话里的旧图片就清掉了。"),
    (32.2, "每一轮都少传一大截。"),
    (35.3, "放心，聊天记录一条都不会丢。"),
    (39.3, "平时，它就是一只普通的小狗。"),
    (43.5, "小黑已经在 GitHub 开源，一行命令就能装。"),
]
let CUTS = [5.0, 17.0, 22.0, 28.0, 35.0, 39.0, 43.0]

// MARK: - 素材（idle/happy/dizzy 三张照片里带着摸它的手，视频里只用没有手的）

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
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func lerp(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }
/// 阻尼弹簧的阶跃响应：0 → 1，略微过冲后停住；是时间的纯函数
func spring(_ x: Double, freq: Double = 1.8, damp: Double = 0.55) -> Double {
    guard x > 0 else { return 0 }
    let w = 2 * .pi * freq, wd = w * sqrt(1 - damp * damp)
    return 1 - exp(-damp * w * x) * (cos(wd * x) + damp * w / wd * sin(wd * x))
}
/// 冲击：0 → 峰值 → 0 的衰减脉冲（镜头猛推一下）
func impulse(_ x: Double, decay: Double = 7) -> Double { x <= 0 ? 0 : x * decay * exp(1 - x * decay) }
func pingpong(_ f: [CGImage], _ t: Double, fps: Double) -> CGImage {
    let n = f.count
    guard n > 1 else { return f[0] }
    let period = 2 * n - 2
    let k = Int(max(0, t) * fps) % period
    return f[k < n ? k : period - k]
}

// MARK: - 画图（左上角为原点，y 向下）

var ctx: CGContext!

let INK: UInt32 = 0x16161a, CREAM: UInt32 = 0xf7f2e8, CREAM2: UInt32 = 0xece3d2
let RED: UInt32 = 0xe8574a, GREEN: UInt32 = 0x2fa36b, NAVY: UInt32 = 0x0e1420, GREY: UInt32 = 0x6b6b73

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
    if shadow > 0 { ctx.setShadow(offset: CGSize(width: 0, height: shadow / 3), blur: shadow, color: rgb(0x000000, 0.16)) }
    ctx.setFillColor(c)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2, r.height / 2),
                       cornerHeight: min(radius, r.width / 2, r.height / 2), transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}

func gradient(_ top: UInt32, _ bottom: UInt32) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: H), options: [])
}

func glow(_ x: Double, _ y: Double, _ r: Double, _ c: UInt32, _ a: Double) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(c, a), rgb(c, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
}

/// 地上的软影子
func groundShadow(_ cx: Double, _ y: Double, _ w: Double, _ a: Double = 0.22) {
    ctx.saveGState()
    ctx.translateBy(x: cx, y: y)
    ctx.scaleBy(x: 1, y: 0.18)
    glow(0, 0, w / 2, 0x000000, a)
    ctx.restoreGState()
}

/// 以脚底中点 (cx, bottom) 为锚点画小狗
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
    CTFontCreateWithName((mono ? "Menlo-Bold" : "PingFangSC-" + weight) as CFString, size, nil)
}
func line(_ s: String, _ f: CTFont, _ c: CGColor) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): c,
    ]))
}
func width(_ s: String, _ f: CTFont) -> Double { CTLineGetTypographicBounds(line(s, f, rgb(0)), nil, nil, nil) }

func drawLine(_ l: CTLine, x: Double, y: Double) {
    var asc: CGFloat = 0, desc: CGFloat = 0
    _ = CTLineGetTypographicBounds(l, &asc, &desc, nil)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x, y: y + (asc - desc) / 2)
    CTLineDraw(l, ctx)
}

@discardableResult
func text(_ s: String, _ x: Double, _ y: Double, size: Double, weight: String = "Semibold",
          color: CGColor = rgb(INK), alpha: Double = 1, align: Double = 0.5, mono: Bool = false) -> Double {
    guard alpha > 0.001 else { return 0 }
    let f = font(size, weight, mono: mono)
    let l = line(s, f, color)
    let w = CTLineGetTypographicBounds(l, nil, nil, nil)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    drawLine(l, x: x - w * align, y: y)
    ctx.restoreGState()
    return w
}

/// 逐字弹出的标题；[方括号] 里的字用强调色。t0 开始进场，t1 开始退场
func headline(_ s: String, _ t: Double, t0: Double, t1: Double = 1e9, y: Double = 150, size: Double = 84,
              color: UInt32 = INK, accent: UInt32 = RED) {
    guard t > t0 - 0.01, t < t1 + 0.4 else { return }
    var chars: [(Character, UInt32)] = []
    var hot = false
    for ch in s {
        if ch == "[" { hot = true; continue }
        if ch == "]" { hot = false; continue }
        chars.append((ch, hot ? accent : color))
    }
    let f = font(size)
    let ws = chars.map { width(String($0.0), f) }
    var x = W / 2 - ws.reduce(0, +) / 2
    let out = easeInOut(prog(t, t1, t1 + 0.35))
    for (i, (ch, c)) in chars.enumerated() {
        let p = spring(t - t0 - Double(i) * 0.035, freq: 2.2, damp: 0.6)
        let a = clamp01(p * 1.6) * (1 - out)
        if a > 0.001 {
            ctx.saveGState()
            ctx.setAlpha(a)
            ctx.clip(to: CGRect(x: x - 4, y: y - size, width: ws[i] + 8, height: size * 2))
            drawLine(line(String(ch), f, rgb(c)), x: x, y: y + (1 - p) * size * 0.9 - out * size * 0.6)
            ctx.restoreGState()
        }
        x += ws[i]
    }
}

/// 对话气泡，尖角朝下指向 (cx, bottom)，弹簧弹出
func bubble(_ s: String, cx: Double, bottom: Double, t: Double, t0: Double, t1: Double = 1e9, size: Double = 34) {
    let p = spring(t - t0, freq: 2.4, damp: 0.5) * (1 - easeInOut(prog(t, t1, t1 + 0.25)))
    guard p > 0.01 else { return }
    let f = font(size)
    let w = width(s, f) + size * 1.6, h = size * 2.1
    let r = CGRect(x: cx - w / 2, y: bottom - h - 16, width: w, height: h)
    ctx.saveGState()
    ctx.setAlpha(clamp01(p * 2))
    ctx.translateBy(x: cx, y: bottom)
    ctx.scaleBy(x: p, y: p)
    ctx.translateBy(x: -cx, y: -bottom)
    fill(r, rgb(0xffffff), radius: h / 2, shadow: 18)
    ctx.setFillColor(rgb(0xffffff))
    ctx.move(to: CGPoint(x: cx - 14, y: r.maxY - 2))
    ctx.addLine(to: CGPoint(x: cx, y: bottom))
    ctx.addLine(to: CGPoint(x: cx + 14, y: r.maxY - 2))
    ctx.fillPath()
    drawLine(line(s, f, rgb(INK)), x: r.minX + size * 0.8, y: r.midY)
    ctx.restoreGState()
}

func arrow(_ x: Double, _ y: Double, scale: Double = 1.7, alpha: Double = 1) {
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
    ctx.setFillColor(rgb(0x111111))
    ctx.setStrokeColor(rgb(0xffffff))
    ctx.setLineWidth(2)
    ctx.setLineJoin(.round)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()
}

func sausage(_ x: Double, _ y: Double, height: Double = 160, scale: Double = 1, rot: Double = 0) {
    guard scale > 0.01 else { return }
    let h = height * scale, w = h * Double(SAUSAGE.width) / Double(SAUSAGE.height)
    ctx.saveGState()
    ctx.translateBy(x: x, y: y)
    ctx.rotate(by: rot)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: rgb(0x000000, 0.3))
    ctx.draw(SAUSAGE, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
    ctx.restoreGState()
}

/// 一张"截图"小卡片
func card(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double, hue: Int, alpha: Double = 1, scale: Double = 1, rot: Double = 0) {
    guard alpha > 0.001, scale > 0.01 else { return }
    let colors: [UInt32] = [0x5b8def, 0xf0a04b, 0x4cb782, 0xe0607e, 0x9b6ef3, 0x2ab0c5]
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: rot)
    ctx.scaleBy(x: scale, y: scale)
    let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    fill(r, rgb(0xffffff), radius: 12, shadow: 10)
    fill(CGRect(x: r.minX, y: r.minY, width: w, height: h * 0.16), rgb(0xe9e9ee), radius: 12)
    fill(CGRect(x: r.minX + w * 0.08, y: r.minY + h * 0.27, width: w * 0.5, height: h * 0.4), rgb(colors[hue % 6]), radius: 7)
    for i in 0..<3 {
        fill(CGRect(x: r.minX + w * 0.64, y: r.minY + h * (0.3 + Double(i) * 0.14), width: w * 0.26, height: h * 0.06), rgb(0xd5d5dc), radius: 3)
    }
    fill(CGRect(x: r.minX + w * 0.08, y: r.minY + h * 0.76, width: w * 0.82, height: h * 0.07), rgb(0xd5d5dc), radius: 3)
    ctx.restoreGState()
}

func quotaBar(x: Double, y: Double, w: Double, frac: Double, label: String, flash: Double = 0) {
    if !label.isEmpty { text(label, x, y - 40, size: 30, weight: "Medium", color: rgb(GREY), align: 0) }
    fill(CGRect(x: x, y: y, width: w, height: 38), rgb(0xdcd5c6), radius: 19)
    let c = frac > 0.5 ? lerpColor(0xf0a04b, GREEN, (frac - 0.5) * 2) : lerpColor(RED, 0xf0a04b, frac * 2)
    fill(CGRect(x: x, y: y, width: max(38, w * frac), height: 38), c, radius: 19)
    if flash > 0 { fill(CGRect(x: x - 6, y: y - 6, width: w + 12, height: 50), rgb(RED, 0.25 * flash), radius: 25) }
    text("\(Int((frac * 100).rounded()))%", x + w + 22, y + 19, size: 32, color: rgb(GREY), align: 0, mono: true)
}

// MARK: - 桌面

func desktop() {
    gradient(0x2f5d8c, 0x8db2da)
    glow(300, 900, 900, 0xffffff, 0.12)
    glow(1600, 100, 800, 0xffd9a0, 0.14)
    fill(CGRect(x: 0, y: 0, width: W, height: 36), rgb(0xffffff, 0.28))
    text("10:24", W - 30, 18, size: 22, weight: "Medium", color: rgb(INK), align: 1)
    let dock = CGRect(x: 600, y: H - 96, width: 720, height: 84)
    fill(dock, rgb(0xffffff, 0.32), radius: 24)
    let icons: [UInt32] = [0x5b8def, 0xf0a04b, 0x4cb782, 0xe0607e, 0x9b6ef3, 0x2ab0c5, 0x1c1c1e, 0xf5c542, 0xff7a59]
    for (i, c) in icons.enumerated() {
        fill(CGRect(x: dock.minX + 22 + Double(i) * 76, y: dock.minY + 12, width: 60, height: 60), rgb(c), radius: 14)
    }
}

// MARK: - 追淀粉肠（逐帧积分，任何时刻都能直接算出来）

let chaseStart = 22.0, chaseStop = 26.4, eatT = 27.0
let dogHome = (x: 1420.0, y: H - 30)
func sausagePos(_ t: Double) -> (Double, Double) {
    let u = min(t, chaseStop) - chaseStart
    let px = 960 + 620 * sin(u * 1.0 - 0.4), py = 560 + 170 * sin(u * 1.8 + 0.6)
    let b = easeInOut(prog(t, chaseStart, chaseStart + 0.9))
    return (lerp(1700, px, b), lerp(860, py, b))
}
func chaseState(_ t: Double) -> (x: Double, y: Double, left: Bool, moving: Bool) {
    var x = dogHome.x, y = dogHome.y, left = true, moving = false
    var tt = chaseStart
    let dt = 1.0 / 120
    while tt < t {
        let (sx, sy) = sausagePos(tt)
        let tx = sx + (left ? 150 : -150), ty = sy + 270
        let dx = tx - x, dy = ty - y, d = hypot(dx, dy)
        let step = min(d, 480.0 * dt)
        moving = d > 8
        if d > 1 { x += dx / d * step; y += dy / d * step; if abs(dx) > 4 { left = dx < 0 } }
        tt += dt
    }
    if t >= chaseStop + 0.3 { moving = false }
    return (x, y, left, moving)
}

// MARK: - 分镜

func scene1(_ t: Double) {
    gradient(NAVY, 0x1c2a40)
    glow(W / 2, 620, 700, 0x5b8def, 0.22)
    let rise = spring(t - 0.5, freq: 1.4, damp: 0.5)
    let by = lerp(H + 60, 660, rise)
    groundShadow(W / 2, 660, 340, 0.45 * rise)
    dog(pingpong(STAND, t, fps: 15), cx: W / 2, bottom: by, height: 420)
    headline("小黑", t, t0: 1.0, y: 770, size: 140, color: 0xffffff)
    headline("给 Codex [省流量] 的桌宠", t, t0: 1.6, y: 880, size: 50, color: 0xb8c4d6, accent: 0xffb08a)
}

func scene2(_ t: Double) {
    gradient(CREAM, CREAM2)
    glow(1460, 420, 600, 0xffffff, 0.6)
    headline("你贴过的 [每一张截图]", t, t0: 5.3, t1: 8.0, y: 140)
    headline("每发一句话 都会被 [重新上传]", t, t0: 8.2, t1: 11.9, y: 140)
    headline("流量和 VPN 额度 [悄悄烧光]", t, t0: 12.1, y: 140)

    // 聊天窗口（弹簧滑入）
    let inP = spring(t - 5.1, freq: 1.5, damp: 0.7)
    ctx.saveGState()
    ctx.translateBy(x: (1 - inP) * -500, y: 0)
    let win = CGRect(x: 170, y: 270, width: 700, height: 660)
    fill(win, rgb(0xffffff), radius: 32, shadow: 30)
    for i in 0..<5 {
        let right = i % 2 == 1
        let w = [420.0, 300, 460, 260, 380][i]
        let a = spring(t - 5.5 - Double(i) * 0.12, freq: 2.5, damp: 0.7)
        fill(CGRect(x: right ? win.maxX - 40 - w : win.minX + 40, y: win.minY + 44 + Double(i) * 94 + (1 - a) * 30,
                    width: w, height: 64), rgb(right ? 0xdbe8ff : 0xf0f0f3, clamp01(a)), radius: 22)
    }
    // 第一屏：聊天里的截图
    for k in 0..<3 {
        let a = spring(t - 5.9 - Double(k) * 0.25, freq: 2.2, damp: 0.55)
        if t < 8.0 { card(win.minX + 170 + Double(k) * 170, win.minY + 300, 150, 112, hue: k, alpha: clamp01(a * 2), scale: a, rot: Double(k - 1) * 0.05) }
    }
    let input = CGRect(x: win.minX + 30, y: win.maxY - 104, width: win.width - 60, height: 72)
    fill(input, rgb(0xf3f3f6), radius: 36)
    text("帮我看看这个报错…", input.minX + 30, input.midY, size: 28, weight: "Regular", color: rgb(0x9a9aa2), align: 0)
    var pulse = 0.0
    for s in sends where t >= s && t < s + 0.3 { pulse = 1 - (t - s) / 0.3 }
    let btn = CGPoint(x: input.maxX - 40, y: input.midY)
    let br = 27 + pulse * 7
    fill(CGRect(x: btn.x - br, y: btn.y - br, width: br * 2, height: br * 2), rgb(INK), radius: br)
    text("↑", btn.x, btn.y, size: 30, color: rgb(0xffffff))
    ctx.restoreGState()

    // 云
    let cloudIn = spring(t - 7.6, freq: 1.8, damp: 0.6)
    let cloud = CGPoint(x: 1460, y: 410)
    ctx.saveGState()
    ctx.translateBy(x: cloud.x, y: cloud.y)
    ctx.scaleBy(x: cloudIn, y: cloudIn)
    ctx.setFillColor(rgb(0xc6d4ea))
    for (dx, dy, r) in [(-95.0, 22.0, 72.0), (0, -22, 100), (100, 22, 72), (0, 44, 82)] {
        ctx.fillEllipse(in: CGRect(x: dx - r, y: dy - r, width: r * 2, height: r * 2))
    }
    text("↑", 0, 10, size: 96, color: rgb(0xffffff))
    ctx.restoreGState()

    // 每拍发一句话，截图全飞上去
    var arrived = 0
    for (k, s) in sends.enumerated() {
        for j in 0..<4 {
            let st = s + Double(j) * 0.06
            let p = prog(t, st, st + 0.7)
            if p >= 1 { arrived += 1; continue }
            guard p > 0 else { continue }
            let e = easeInOut(p)
            let x0 = win.midX - 180 + Double(j) * 120, y0 = win.minY + 300
            let cx = lerp(x0, cloud.x, e), cy = lerp(y0, cloud.y, e) - sin(e * .pi) * 180
            card(cx, cy, 130, 96, hue: k + j, alpha: 1 - prog(p, 0.85, 1), scale: lerp(1, 0.3, e), rot: e * 0.4)
        }
    }
    let mb = Double(arrived) * 8.8
    let cIn = prog(t, 7.9, 8.2)
    text("已上传", cloud.x, 580, size: 34, weight: "Medium", color: rgb(GREY), alpha: cIn)
    text(String(format: "%.0f MB", mb), cloud.x, 650, size: 86, color: rgb(RED), alpha: cIn, mono: true)
    let flash = t > 12.0 ? max(0, cos((t - 12.0) / BEAT * .pi)) * (1 - prog(t, 16, 17)) : 0
    quotaBar(x: 1160, y: 800, w: 560, frac: 1 - 0.86 * mb / (Double(sends.count) * 4 * 8.8), label: "VPN / 代理剩余额度", flash: flash)
}
let sends = (0..<9).map { 8.0 + Double($0) * BEAT }

func scene3(_ t: Double) {
    desktop()
    headline("右下角 · [晃晃鼠标]", t, t0: 17.3, t1: 19.9, y: 160, color: 0xffffff, accent: 0xffd27a)
    headline("[淀粉肠]！小黑钻出来了", t, t0: 20.1, y: 160, color: 0xffffff, accent: 0xffd27a)

    let base = (x: 1700.0, y: 860.0)
    let inP = easeOut(prog(t, 17.4, 18.2))
    func cx(_ tt: Double) -> Double {
        let a = tt > 18.5 && tt < 20.0 ? 100.0 * min(1, (tt - 18.5) / 0.15) : 0
        return lerp(1200, base.x, inP) + sin((tt - 18.5) * 2 * .pi * 2) * a   // 一拍两下
    }
    let cy = lerp(520, base.y, inP)
    if t > 18.5 && t < 20.0 {
        for k in 1...6 { arrow(cx(t - Double(k) * 0.02), cy, alpha: 0.16 * Double(7 - k) / 6) }
    }
    let pop = prog(t, 20.0, 20.15)
    arrow(cx(t), cy, scale: 1.7 * (1 - pop))
    if t >= 20.0 {
        let s = spring(t - 20.0, freq: 2.6, damp: 0.45)
        glow(base.x, base.y + 20, 160 * s, 0xffd27a, 0.5 * (1 - prog(t, 20.0, 20.8)))
        sausage(base.x, base.y + 20, scale: s, rot: sin(t * 3) * 0.06)
    }
    if t > 20.4 {
        let rise = spring(t - 20.5, freq: 1.8, damp: 0.5)
        groundShadow(dogHome.x, dogHome.y, 260, 0.3 * clamp01(rise))
        dog(pingpong(STAND, t, fps: 15), cx: dogHome.x, bottom: lerp(H + 380, dogHome.y, rise), height: 340)
        bubble("汪！淀粉肠！", cx: dogHome.x, bottom: dogHome.y - 360, t: t, t0: 21.0)
    }
}

func scene4(_ t: Double) {
    desktop()
    headline("站起来作揖 · [一蹦一蹦地追]", t, t0: 22.3, t1: 26.8, y: 160, color: 0xffffff, accent: 0xffd27a)
    headline("[嗷呜]！", t, t0: 27.0, y: 160, size: 110, color: 0xffffff, accent: 0xffd27a)
    let (sx, sy) = sausagePos(t)
    let s = chaseState(t)
    if t < eatT {
        // 一拍两跳，跳的时候影子变小
        let ph = (t - chaseStart) / (BEAT / 2)
        let hop = s.moving ? abs(sin(ph * .pi)) * 22 : 0
        groundShadow(s.x, s.y, 200 - hop * 2, 0.18)
        dog(pingpong(BEG, t, fps: 15), cx: s.x, bottom: s.y - hop, height: 310, flip: !s.left, sy: 1 + (hop > 18 ? 0.03 : 0))
    } else {
        let b = spring(t - eatT, freq: 2.2, damp: 0.35)
        let jump = sin(clamp01((t - eatT) / 0.5) * .pi) * 60
        groundShadow(s.x, s.y, 220, 0.2)
        dog(pingpong(STAND, t, fps: 15), cx: s.x, bottom: s.y - jump, height: 310, sx: 2 - b, sy: b)
        bubble("嗷呜～好吃！", cx: s.x, bottom: s.y - 330 - jump, t: t, t0: eatT + 0.1)
    }
    if t < eatT + 0.3 {
        // 吃的时候淀粉肠缩进小狗嘴里
        let e = easeInOut(prog(t, eatT - 0.35, eatT + 0.1))
        let mx = lerp(sx, s.x, e), my = lerp(sy, s.y - 240, e)
        sausage(mx, my, scale: 1 - prog(t, eatT, eatT + 0.2), rot: sin(t * 3) * 0.06)
    }
}

func scene5(_ t: Double) {
    gradient(CREAM, CREAM2)
    headline("点它一下 · [清掉旧图片]", t, t0: 28.3, t1: 31.9, y: 140)
    headline("每一轮 [少传一大截]", t, t0: 32.2, y: 140, accent: GREEN)

    let dx = 520.0, db = 920.0
    let click = 29.0, done = 31.5
    groundShadow(dx, db, 300, 0.2)
    if t < click + 0.05 {
        dog(LOOK[0], cx: dx, bottom: db, height: 390)
    } else if t < done {
        dog(pingpong(STAND, t, fps: 15), cx: dx, bottom: db, height: 410, rot: sin(t * 2 * .pi / 0.25) * 0.07)
        bubble("呜呜，正在清理…", cx: dx, bottom: db - 430, t: t, t0: click + 0.1, t1: done - 0.1)
    } else {
        let jump = sin(clamp01((t - done) / 0.5) * .pi) * 50
        dog(pingpong(STAND, t, fps: 15), cx: dx, bottom: db - jump, height: 410)
        bubble("清掉 12 张图！", cx: dx, bottom: db - 430 - jump, t: t, t0: done + 0.1)
    }
    // 光标点一下
    let mv = easeInOut(prog(t, 28.2, 28.9))
    let ax = lerp(880, dx + 10, mv), ay = lerp(640, 700, mv)
    arrow(ax, ay, alpha: (prog(t, 28.0, 28.2)) * (1 - prog(t, 29.6, 29.9)))
    if t > click && t < click + 0.5 {
        let p = easeOut(prog(t, click, click + 0.5))
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0x5b8def, 1 - p))
        ctx.setLineWidth(6)
        let r = 20 + p * 80
        ctx.strokeEllipse(in: CGRect(x: ax - r, y: ay - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
    }

    // 右边：会话里的图片一张张变成 1×1 占位图（十六分音符一张）
    for k in 0..<12 {
        let col = Double(k % 4), row = Double(k / 4)
        let cx = 1060 + col * 200, cy = 340 + row * 160
        let a = spring(t - 28.3 - Double(k) * 0.04, freq: 2.2, damp: 0.6)
        let st = cardPops[k]
        let p = easeInOut(prog(t, st - 0.05, st + 0.2))
        if p < 1 { card(cx, cy, 170, 126, hue: k, alpha: clamp01(a * 2), scale: a * (1 - p * 0.93)) }
        if p > 0.6 { fill(CGRect(x: cx - 7, y: cy - 7, width: 14, height: 14), rgb(0xb9b6ad, prog(p, 0.6, 1)), radius: 3) }
    }
    let q = easeInOut(prog(t, cardPops[0], cardPops[11] + 0.2))
    let mb = lerp(106, 0.2, q)
    let pin = prog(t, 28.6, 28.9)
    text("每轮上传", 1000, 790, size: 34, weight: "Medium", color: rgb(GREY), alpha: pin, align: 0)
    text(String(format: mb < 1 ? "%.1f MB" : "%.0f MB", mb), 1170, 790, size: 72,
         color: lerpColor(RED, GREEN, q), alpha: pin, align: 0, mono: true)
    let refill = easeInOut(prog(t, done, done + 1.0))
    quotaBar(x: 1000, y: 870, w: 620, frac: lerp(0.14, 1, refill), label: "")
}
let cardPops = (0..<12).map { 29.5 + Double($0) * BEAT / 4 }

func scene6(_ t: Double) {
    gradient(0xeef6f0, 0xdcecdf)
    headline("聊天记录 [一条不丢]", t, t0: 35.3, y: 130, accent: GREEN)
    let inP = spring(t - 35.1, freq: 1.6, damp: 0.7)
    ctx.saveGState()
    ctx.translateBy(x: 0, y: (1 - inP) * 600)
    let panel = CGRect(x: 520, y: 230, width: 880, height: 630)
    fill(panel, rgb(0xffffff), radius: 30, shadow: 30)
    let titles = ["做一个有趣的小游戏", "App 审核被拒了，帮我看看", "从 0 开始教我作曲编曲", "修一下登录页的 bug", "整理客户资料表", "写这周的周报"]
    for (i, s) in titles.enumerated() {
        let y = panel.minY + 60 + Double(i) * 98
        let fixT = checks[i]
        let fix = spring(t - fixT, freq: 2.4, damp: 0.5)
        if i > 0 { fill(CGRect(x: panel.minX + 40, y: y - 49, width: panel.width - 80, height: 2), rgb(0xeeeeee)) }
        text(s, panel.minX + 60, y, size: 34, weight: "Medium", color: rgb(INK), alpha: 0.35 + 0.65 * clamp01(fix), align: 0)
        text("记录为空", panel.maxX - 60, y, size: 26, weight: "Medium", color: rgb(RED), alpha: 1 - prog(t, fixT, fixT + 0.15), align: 1)
        if t > fixT {
            let r = 24 * fix
            fill(CGRect(x: panel.maxX - 84 - r, y: y - r, width: r * 2, height: r * 2), rgb(GREEN), radius: r)
            text("✓", panel.maxX - 84, y, size: 30 * fix, color: rgb(0xffffff))
        }
    }
    ctx.restoreGState()
    text("清理时保持每行字节数不变，Codex 的索引始终对得上", W / 2, 925, size: 30, weight: "Medium",
         color: rgb(GREY), alpha: prog(t, 37.5, 37.9))
    groundShadow(1690, H - 30, 220, 0.2)
    dog(pingpong(LOOK, t - 35, fps: 6), cx: 1690, bottom: H - 30, height: 290)
}
let checks = (0..<6).map { 35.8 + Double($0) * BEAT }

func scene7(_ t: Double) {
    gradient(0xfff6e9, 0xf6e5cc)
    headline("平时，就是一只 [普通的小狗]", t, t0: 39.3, y: 130)
    let items: [(String, Double)] = [("闲着会张望", 400), ("摸久了翻肚皮", 960), ("没人理就睡觉", 1520)]
    for (i, it) in items.enumerated() {
        let a = spring(t - (39.5 + Double(i) * BEAT), freq: 2.0, damp: 0.5)
        guard a > 0.01 else { continue }
        ctx.saveGState()
        ctx.translateBy(x: it.1, y: 580)
        ctx.scaleBy(x: a, y: a)
        ctx.rotate(by: (1 - a) * 0.2 * (i == 1 ? -1 : 1))
        ctx.translateBy(x: -it.1, y: -580)
        let r = CGRect(x: it.1 - 250, y: 260, width: 500, height: 640)
        fill(r, rgb(0xffffff), radius: 34, shadow: 26)
        switch i {
        case 0:
            groundShadow(it.1, 780, 260, 0.15)
            dog(pingpong(LOOK, t - 39.5, fps: 10), cx: it.1, bottom: 780, height: 420)
        case 1:
            groundShadow(it.1, 740, 300, 0.15)
            dog(BELLY, cx: it.1, bottom: 740, height: 300, rot: sin(t * 2 * .pi / (BEAT * 2)) * 0.05)
        default:
            groundShadow(it.1, 740, 300, 0.15)
            dog(SLEEP, cx: it.1, bottom: 740, height: 300, sy: 1 + sin(t * 2 * .pi / 2) * 0.03)
            for k in 0..<3 {
                let p = ((t - 40.5) / 2 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                guard t > 40.5, p >= 0 else { continue }
                text("Z", it.1 + 110 + p * 70, 470 - p * 150, size: 30 + p * 26, color: rgb(0x5b6b8c), alpha: sin(p * .pi))
            }
        }
        text(it.0, it.1, 840, size: 40)
        ctx.restoreGState()
    }
}

func scene8(_ t: Double) {
    gradient(NAVY, 0x1c2a40)
    glow(W / 2, 450, 650, 0x5b8def, 0.2)
    let rise = spring(t - 43.1, freq: 1.5, damp: 0.55)
    groundShadow(W / 2, 540, 300, 0.4 * clamp01(rise))
    dog(pingpong(STAND, t, fps: 15), cx: W / 2, bottom: lerp(H + 300, 540, rise), height: 370)
    headline("小黑 CodexDog", t, t0: 43.5, y: 630, size: 90, color: 0xffffff)
    headline("给 Codex [省流量] 的 macOS 桌宠", t, t0: 44.0, y: 718, size: 42, color: 0xb8c4d6, accent: 0xffb08a)
    let u = spring(t - 45.0, freq: 2, damp: 0.7)
    text("github.com/zio005792-blip/CodexDog", W / 2, 800 + (1 - u) * 30, size: 40, color: rgb(0x7fd1ff), alpha: clamp01(u), mono: true)
    text("MIT 开源 · 一行命令安装", W / 2, 862, size: 30, weight: "Medium", color: rgb(0x8a96a8), alpha: prog(t, 45.5, 46.0))
}

// MARK: - 镜头、转场、质感

/// 每个场景慢慢推近；关键时刻猛推一下
func camera(_ t: Double) -> (Double, Double, Double) {
    let start = ([0.0] + CUTS).last(where: { $0 <= t }) ?? 0
    var s = 1 + 0.035 * easeInOut(prog(t, start, start + 6))
    var dy = 0.0
    for e in [20.0, eatT, 31.5] { s += 0.045 * impulse(t - e) }
    // 额度烧光时轻轻抖一下
    if t > 12.1 && t < 13.0 { dy = sin(t * 90) * 6 * (1 - prog(t, 12.1, 13.0)) }
    return (s, W / 2, H / 2 + dy)
}

func scene(_ t: Double) {
    switch t {
    case ..<5: scene1(t)
    case ..<17: scene2(t)
    case ..<22: scene3(t)
    case ..<28: scene4(t)
    case ..<35: scene5(t)
    case ..<39: scene6(t)
    case ..<43: scene7(t)
    default: scene8(t)
    }
}

/// 字幕条
func subtitle(_ t: Double) {
    guard let (st, s) = VO.last(where: { $0.0 <= t }) else { return }
    let end = st + voLen[s, default: 3] + 0.15
    let a = prog(t, st, st + 0.15) * (1 - prog(t, end, end + 0.2))
    guard a > 0.01 else { return }
    let f = font(36, "Medium")
    let w = width(s, f) + 64
    // 桌面场景底下有 Dock，字幕抬高一点
    let cy = t >= 17 && t < 28 ? H - 150 : H - 70
    ctx.saveGState()
    ctx.setAlpha(a)
    fill(CGRect(x: W / 2 - w / 2, y: cy - 32, width: w, height: 64), rgb(0x000000, 0.55), radius: 32)
    drawLine(line(s, f, rgb(0xffffff)), x: W / 2 - w / 2 + 32, y: cy)
    ctx.restoreGState()
}

/// 圆形划变：旧场景被一个圆盖住，再从圆里露出新场景
func wipe(_ t: Double) {
    let R = hypot(W, H) / 2 + 40
    for c in CUTS {
        if t > c - 0.3 && t < c {
            let r = R * easeInOut(prog(t, c - 0.3, c))
            ctx.setFillColor(rgb(INK))
            ctx.fillEllipse(in: CGRect(x: W / 2 - r, y: H / 2 - r, width: r * 2, height: r * 2))
        } else if t >= c && t < c + 0.3 {
            let r = R * easeInOut(prog(t, c, c + 0.3))
            ctx.addRect(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.addEllipse(in: CGRect(x: W / 2 - r, y: H / 2 - r, width: r * 2, height: r * 2))
            ctx.setFillColor(rgb(INK))
            ctx.fillPath(using: .evenOdd)
        }
    }
}

let GRAIN: CGImage = {
    let n = 256
    var px = [UInt8](repeating: 0, count: n * n * 4)
    var seed: UInt64 = 42
    for i in 0..<(n * n) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let v = UInt8(truncatingIfNeeded: seed >> 56)
        px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
    }
    let c = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return c.makeImage()!
}()

func finish(_ t: Double, frame: Int) {
    // 暗角
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(0, 0), rgb(0, 0.28)] as CFArray, locations: [0.55, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: W / 2, y: H / 2), startRadius: 0,
                           endCenter: CGPoint(x: W / 2, y: H / 2), endRadius: hypot(W, H) / 2, options: [.drawsAfterEndLocation])
    // 颗粒
    ctx.saveGState()
    ctx.setAlpha(0.035)
    ctx.setBlendMode(.overlay)
    let ox = Double((frame * 73) % 256), oy = Double((frame * 151) % 256)
    var y = -oy
    while y < H { var x = -ox; while x < W { ctx.draw(GRAIN, in: CGRect(x: x, y: y, width: 256, height: 256)); x += 256 }; y += 256 }
    ctx.restoreGState()
    // 开头淡入、结尾淡出
    let fade = max(1 - prog(t, 0, 0.5), prog(t, DUR - 1.0, DUR))
    if fade > 0 { fill(CGRect(x: 0, y: 0, width: W, height: H), rgb(0x000000, fade)) }
}

func render(_ t: Double) {
    let (s, cx, cy) = camera(t)
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: -W / 2, y: -H / 2)
    scene(t)
    ctx.restoreGState()
    wipe(t)
    subtitle(t)
}

// MARK: - 声音

let SR = 48000.0
let NS = Int(DUR * SR)
var musL = [Float](repeating: 0, count: NS), musR = musL
var sfx = [Float](repeating: 0, count: NS)
var voLen: [String: Double] = [:]

func mtof(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
var rng: UInt64 = 7
func noise() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(Int64(bitPattern: rng >> 1) % 2_000_000) / 1_000_000 - 1 }

func add(_ buf: inout [Float], _ t: Double, _ len: Double, gain: Double, _ f: (Double) -> Double) {
    let s0 = Int(t * SR), n = Int(len * SR)
    for i in 0..<n where s0 + i >= 0 && s0 + i < NS {
        let v = f(Double(i) / SR) * gain
        buf[s0 + i] += Float(v)
    }
}

// 乐器
func pluck(_ t: Double, _ note: Double, _ len: Double, gain: Double, into b: inout [Float]) {
    let fr = mtof(note)
    add(&b, t, len + 0.6, gain: gain) { x in
        let env = min(1, x / 0.004) * exp(-x * 5.5)
        return env * (sin(2 * .pi * fr * x) + 0.35 * sin(4 * .pi * fr * x) * exp(-x * 9) + 0.12 * sin(6 * .pi * fr * x) * exp(-x * 14))
    }
}
func bell(_ t: Double, _ note: Double, gain: Double, into b: inout [Float]) {
    let fr = mtof(note)
    add(&b, t, 1.6, gain: gain) { x in
        let env = min(1, x / 0.002) * exp(-x * 3.2)
        return env * (sin(2 * .pi * fr * x + 1.2 * sin(2 * .pi * fr * 3.5 * x) * exp(-x * 6)) + 0.2 * sin(2 * .pi * fr * 2 * x))
    }
}
func bass(_ t: Double, _ note: Double, _ len: Double, gain: Double, into b: inout [Float]) {
    let fr = mtof(note)
    add(&b, t, len, gain: gain) { x in
        let env = min(1, x / 0.01) * (1 - prog(x, len - 0.05, len)) * exp(-x * 1.5)
        let ph = (fr * x).truncatingRemainder(dividingBy: 1)
        return env * (ph < 0.5 ? 4 * ph - 1 : 3 - 4 * ph) * 0.8 + env * 0.3 * sin(2 * .pi * fr * x)
    }
}
func pad(_ t: Double, _ notes: [Double], _ len: Double, gain: Double, into b: inout [Float]) {
    for n in notes {
        let fr = mtof(n)
        add(&b, t, len + 0.4, gain: gain / Double(notes.count)) { x in
            let env = min(1, x / 0.35) * (1 - prog(x, len, len + 0.4))
            return env * (sin(2 * .pi * fr * x) + 0.5 * sin(2 * .pi * fr * 1.003 * x) + 0.25 * sin(4 * .pi * fr * x))
        }
    }
}
func kick(_ t: Double, gain: Double, into b: inout [Float]) {
    add(&b, t, 0.35, gain: gain) { x in
        let f = 45 + 110 * exp(-x * 30)
        return exp(-x * 9) * sin(2 * .pi * f * x * (1 + exp(-x * 30) * 0.3))
    }
}
func clap(_ t: Double, gain: Double, into b: inout [Float]) {
    var prev = 0.0
    add(&b, t, 0.2, gain: gain) { x in
        let n = noise(); let hp = n - prev; prev = n
        let env = (exp(-x * 30) + 0.6 * exp(-max(0, x - 0.012) * 25) * (x > 0.012 ? 1 : 0))
        return hp * env * 0.6
    }
}
func hat(_ t: Double, gain: Double, into b: inout [Float]) {
    var prev = 0.0
    add(&b, t, 0.05, gain: gain) { x in let n = noise(); let hp = n - prev; prev = n; return hp * exp(-x * 90) }
}

// 音效
func sPop(_ t: Double, gain: Double = 0.35, pitch: Double = 1) {
    add(&sfx, t, 0.12, gain: gain) { x in
        let f = (380 + 700 * exp(-x * 40)) * pitch
        return sin(2 * .pi * f * x) * exp(-x * 28)
    }
}
func sTick(_ t: Double, gain: Double = 0.12) {
    add(&sfx, t, 0.05, gain: gain) { x in sin(2 * .pi * 2600 * x) * exp(-x * 120) }
}
func sWhoosh(_ t: Double, len: Double = 0.4, gain: Double = 0.25) {
    var lp = 0.0
    add(&sfx, t, len, gain: gain) { x in
        let p = x / len
        let cutoff = 0.02 + 0.25 * sin(p * .pi)
        lp += (noise() - lp) * cutoff
        return lp * sin(p * .pi) * 2.2
    }
}
func sBoing(_ t: Double, gain: Double = 0.3) {
    add(&sfx, t, 0.45, gain: gain) { x in
        let f = 180 + 420 * (1 - exp(-x * 8)) + 25 * sin(x * 2 * .pi * 14)
        return sin(2 * .pi * f * x) * exp(-x * 6) * min(1, x / 0.01)
    }
}
func sDing(_ t: Double, gain: Double = 0.22, note: Double = 84) { bell(t, note, gain: gain, into: &sfx) }
func sClick(_ t: Double) {
    add(&sfx, t, 0.03, gain: 0.35) { x in noise() * exp(-x * 220) }
    add(&sfx, t, 0.04, gain: 0.25) { x in sin(2 * .pi * 1800 * x) * exp(-x * 140) }
}
func sNom(_ t: Double) {
    for k in 0..<2 {
        add(&sfx, t + Double(k) * 0.16, 0.13, gain: 0.32) { x in
            let f = 220 - 60 * x / 0.13
            let sq = sin(2 * .pi * f * x) > 0 ? 1.0 : -1.0
            return (0.5 * sq + sin(2 * .pi * f * x)) * sin(.pi * min(1, x / 0.13)) * 0.6
        }
    }
}
func sSweep(_ t: Double, len: Double, from: Double, to: Double, gain: Double) {
    var ph = 0.0
    add(&sfx, t, len, gain: gain) { x in
        let f = from * pow(to / from, x / len)
        ph += 2 * .pi * f / SR
        return sin(ph) * sin(.pi * x / len)
    }
}
func sThump(_ t: Double, gain: Double = 0.1) {
    add(&sfx, t, 0.08, gain: gain) { x in sin(2 * .pi * (90 + 60 * exp(-x * 50)) * x) * exp(-x * 40) }
}

func compose() {
    // 和弦进行：C – Am – F – G，一小节一个
    let prog4: [(Double, [Double])] = [(48, [60, 64, 67, 72]), (45, [57, 60, 64, 69]), (41, [53, 57, 60, 65]), (43, [55, 59, 62, 67])]
    let bars = Int(DUR / 2)
    var chords = [Float](repeating: 0, count: NS)
    var lead = [Float](repeating: 0, count: NS)
    var drums = [Float](repeating: 0, count: NS)
    var low = [Float](repeating: 0, count: NS)
    // 主旋律：五声音阶的小动机，每小节一句
    let motifs: [[(Double, Double)]] = [
        [(0, 76), (0.5, 79), (1.0, 81), (1.5, 79)],
        [(0, 76), (0.5, 72), (0.75, 74), (1.0, 76)],
        [(0, 77), (0.5, 76), (1.0, 72), (1.5, 74)],
        [(0, 74), (0.5, 79), (1.0, 76), (1.25, 74), (1.5, 72)],
    ]
    for b in 0..<bars {
        let t0 = Double(b) * 2
        let (root, notes) = prog4[b % 4]
        let ending = t0 >= 46
        if ending {
            pad(t0, [48, 55, 60, 64, 67, 72], 3, gain: 0.5, into: &chords)
            bell(t0, 84, gain: 0.25, into: &lead); bell(t0 + 0.02, 79, gain: 0.18, into: &lead)
            bass(t0, 36, 2.6, gain: 0.35, into: &low)
            break
        }
        pad(t0, notes, 2, gain: 0.32, into: &chords)
        // 电钢琴在反拍上
        for k in 0..<4 where t0 >= 4 {
            for n in notes.prefix(3) { pluck(t0 + Double(k) * BEAT + BEAT / 2, n, 0.2, gain: 0.05, into: &chords) }
        }
        if t0 >= 4 {
            for k in 0..<8 { bass(t0 + Double(k) * 0.25, root + (k % 4 == 3 ? 7 : 0), 0.22, gain: 0.28, into: &low) }
            for k in 0..<4 {
                let tb = t0 + Double(k) * BEAT
                if k % 2 == 0 { kick(tb, gain: 0.55, into: &drums) } else { clap(tb, gain: 0.22, into: &drums) }
                hat(tb + BEAT / 2, gain: 0.07, into: &drums)
                hat(tb, gain: 0.04, into: &drums)
            }
        }
        // 开头、合集、结尾旋律响一点
        let loud = t0 < 4 || (t0 >= 38 && t0 < 46)
        for (dt, n) in motifs[b % 4] { bell(t0 + dt, n, gain: loud ? 0.16 : 0.12, into: &lead) }
    }
    // 简单混响（几路梳状滤波）给和弦和旋律
    var wet = [Float](repeating: 0, count: NS)
    for (d, g) in [(1557, 0.42), (1617, 0.4), (1491, 0.41), (1422, 0.43)] {
        var buf = [Float](repeating: 0, count: NS)
        for i in 0..<NS {
            let x = chords[i] + lead[i]
            buf[i] = x + (i >= d * 3 ? Float(g) * buf[i - d * 3] : 0)
        }
        for i in 0..<NS { wet[i] += buf[i] * 0.12 }
    }
    for i in 0..<NS {
        let c = chords[i] + lead[i]
        musL[i] = c * 0.9 + wet[i] + drums[i] + low[i]
        musR[i] = c * 0.9 + (i > 600 ? wet[i - 600] : 0) + drums[i] + low[i]
    }

    // 音效时间点
    for c in CUTS { sWhoosh(c - 0.32, len: 0.45, gain: 0.22) }
    sBoing(0.5, gain: 0.22)
    for k in 0..<3 { sPop(5.9 + Double(k) * 0.25, gain: 0.25, pitch: 1 + Double(k) * 0.1) }
    sPop(7.6, gain: 0.25, pitch: 0.8)
    for s in sends {
        sClick(s)
        for j in 0..<4 { sTick(s + Double(j) * 0.06 + 0.7, gain: 0.08) }
    }
    sSweep(12.1, len: 0.9, from: 600, to: 120, gain: 0.12)
    for k in 0..<6 { sWhoosh(18.5 + Double(k) * 0.25, len: 0.22, gain: 0.12) }
    sPop(20.0, gain: 0.45, pitch: 1.2)
    sBoing(20.5, gain: 0.3)
    sPop(21.0, gain: 0.3, pitch: 1.4)
    var h = chaseStart + BEAT / 2
    while h < chaseStop { sThump(h, gain: 0.12); h += BEAT / 2 }
    sNom(eatT)
    sPop(eatT + 0.1, gain: 0.3, pitch: 1.5)
    sClick(29.0)
    for (k, s) in cardPops.enumerated() { sPop(s, gain: 0.2, pitch: 0.8 + Double(k) * 0.07) }
    sSweep(29.5, len: 1.6, from: 900, to: 300, gain: 0.07)
    sDing(31.5, gain: 0.25, note: 88)
    sSweep(31.5, len: 1.0, from: 300, to: 900, gain: 0.07)
    for (k, c) in checks.enumerated() { sDing(c, gain: 0.16, note: [79, 81, 84, 86, 88, 91][k]) }
    for k in 0..<3 { sPop(39.5 + Double(k) * BEAT, gain: 0.28, pitch: 1 + Double(k) * 0.15) }
    sBoing(43.1, gain: 0.22)
}

func loadVO() {
    let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("vo")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (i, (t, s)) in VO.enumerated() {
        let url = dir.appendingPathComponent(String(format: "vo%02d.wav", i))
        if !FileManager.default.fileExists(atPath: url.path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", "Tingting", "-r", "200", "--data-format=LEF32@48000", "-o", url.path, s]
            try! p.run(); p.waitUntilExit()
        }
        let f = try! AVAudioFile(forReading: url)
        let n = AVAudioFrameCount(f.length)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
        try! f.read(into: buf)
        let ch = buf.floatChannelData![0]
        voLen[s] = Double(n) / f.processingFormat.sampleRate
        _ = (t, ch)
    }
}

func mixdown() -> ([Float], [Float]) {
    var L = [Float](repeating: 0, count: NS), R = L
    var peak: Float = 0
    for i in 0..<NS {
        let fadeOut = Float(1 - prog(Double(i) / SR, DUR - 1.5, DUR))
        let fadeIn = Float(prog(Double(i) / SR, 0, 0.3))
        let m = 0.55 * fadeOut * fadeIn
        L[i] = musL[i] * m + sfx[i] * 0.9
        R[i] = musR[i] * m + sfx[i] * 0.9
        peak = max(peak, abs(L[i]), abs(R[i]))
    }
    // 软削波 + 归一到 -1 dBFS
    let g = 0.89 / max(peak, 0.01)
    for i in 0..<NS { L[i] = Float(tanh(Double(L[i] * g) * 1.1) / tanh(1.1)) * 0.89; R[i] = Float(tanh(Double(R[i] * g) * 1.1) / tanh(1.1)) * 0.89 }
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

/// 运动模糊：一帧里取几个子帧叠在一起
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
    finish(t, frame: f)
}

loadVO()
let args = CommandLine.arguments
if args.count > 3 && args[1] == "--still" {
    for s in args[2].split(separator: ",") {
        let t = Double(s)!
        let c = makeContext(nil, bytesPerRow: Int(W) * 4)
        renderFrame(Int(t * FPS), into: c)
        let url = URL(fileURLWithPath: args[3]).appendingPathComponent(String(format: "still_%05.2f.png", t))
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, c.makeImage()!, nil)
        CGImageDestinationFinalize(d)
    }
    exit(0)
}

let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "xiaohei_intro.mp4")
let tmpDir = FileManager.default.temporaryDirectory
let silent = tmpDir.appendingPathComponent("xiaohei_silent.mp4"), wav = tmpDir.appendingPathComponent("xiaohei_audio.wav")

print("合成声音…")
compose()
let (L, R) = mixdown()
writeWAV(L, R, wav)

print("渲染画面…")
try? FileManager.default.removeItem(at: silent)
let writer = try! AVAssetWriter(outputURL: silent, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
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
    let target = makeContext(CVPixelBufferGetBaseAddress(pb!), bytesPerRow: CVPixelBufferGetBytesPerRow(pb!))
    renderFrame(f, into: target)
    CVPixelBufferUnlockBaseAddress(pb!, [])
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(FPS)))
    if f % 300 == 0 { print("  \(f)/\(total)") }
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()

print("合成音轨…")
// 先把 WAV 转成 AAC，再和视频直接拼进 MP4（视频不重新编码）
let m4a = tmpDir.appendingPathComponent("xiaohei_audio.m4a")
try? FileManager.default.removeItem(at: m4a)
let aac = AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A)!
aac.outputURL = m4a
aac.outputFileType = .m4a
aac.exportAsynchronously { sem.signal() }
sem.wait()
let comp = AVMutableComposition()
let vAsset = AVURLAsset(url: silent), aAsset = AVURLAsset(url: m4a)
let range = CMTimeRange(start: .zero, duration: CMTime(seconds: DUR, preferredTimescale: 600))
try! comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    .insertTimeRange(range, of: vAsset.tracks(withMediaType: .video)[0], at: .zero)
try! comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    .insertTimeRange(range, of: aAsset.tracks(withMediaType: .audio)[0], at: .zero)
try? FileManager.default.removeItem(at: out)
let exporter = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
exporter.outputURL = out
exporter.outputFileType = .mp4
exporter.exportAsynchronously { sem.signal() }
sem.wait()
print(exporter.status == .completed ? "完成 \(out.path)" : "失败 \(String(describing: exporter.error))")
