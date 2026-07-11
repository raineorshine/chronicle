import Foundation

let arguments = CommandLine.arguments
let exitCode: Int32
if arguments.contains("--demo") {
    exitCode = Extractor.runDemo()
} else {
    exitCode = await Extractor.run()
}
exit(exitCode)
