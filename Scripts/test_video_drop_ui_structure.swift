import Foundation

@inline(__always)
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum VideoDropUIStructureSmoke {
    static func main() throws {
        let rootPath = CommandLine.arguments.dropFirst().first
            ?? FileManager.default.currentDirectoryPath
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let contentView = try String(
            contentsOf: root.appendingPathComponent("Sources/WallpaperConverter/ContentView.swift"),
            encoding: .utf8
        )
        let dropZone = try String(
            contentsOf: root.appendingPathComponent("Sources/WallpaperConverter/VideoDropZone.swift"),
            encoding: .utf8
        )

        require(contentView.contains("VideoDropZone("), "ContentView must use the dedicated drop zone")
        require(contentView.contains("Button(\"载入\")"), "ContentView must expose an explicit path load button")
        require(contentView.contains("model.loadVideoFromPathField()"), "path submit must use the existing load route")
        require(!contentView.contains(".onDrop("), "ContentView must not attach drop handling to the input TextField container")
        require(dropZone.contains(".onDrop("), "VideoDropZone must own the file-drop handler")
        require(dropZone.contains("let onDrop: ([NSItemProvider]) -> Bool"), "drop zone must accept providers from Finder")
        require(dropZone.contains("Text(\"将本地视频拖到这里\")"), "drop zone must expose the Finder drop affordance")

        print("video drop UI structure tests passed")
    }
}
