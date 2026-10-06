# PDF Kit for Mac

The Mac version of PDF Kit: a free PDF editor with no sign-up and no ads.
Your files stay on your Mac. Same name, colours, logo and tools as the Android,
Windows and web versions (https://hanonhein.github.io/PDFkit/).

Native app: Swift, SwiftUI and Apple's PDFKit, Vision and Core Image. No third-party code.

## Build and run

Needs macOS 14 or newer and the Xcode Command Line Tools (`xcode-select --install`).
The full Xcode app is not needed.

    ./build-app.sh
    open "build/PDF Kit.app"

`build-app.sh` compiles `Sources/PDFKitMac/*.swift` with `swiftc`, makes `build/PDF Kit.app`
(with the app icon from `Resources/pdfkit-icon.png`) and signs it for this Mac.

## Tools

View, Edit (pen, highlighter, text, shapes, signature, picture, stamp), Convert
(PDF to and from Word, Excel, PowerPoint, RTF, text, images, HTML, XML), Merge, Split,
Page tools (rotate, reorder, delete, duplicate, crop, extract), Sign, Scan with iPhone,
Recognize text (OCR), PDF to text, Extract images, Fill form, Protect, Remove password,
Watermark, Page numbers, PDF info, Compress, Grayscale.
