// swift-tools-version:6.2

import PackageDescription
import Foundation

let xylem =
    Package(name: "xylem",
            platforms: [.macOS(.v26)],
            products: [
              .library(name: "XMLCore", targets: ["XMLCore"]),
              .library(name: "SAXParser", targets: ["SAXParser"]),
              .library(name: "DOMParser", targets: ["DOMParser"]),
              .library(name: "XPath", targets: ["XPath"]),
            ],
            targets: [
              .target(name: "XMLCore"),
              .target(name: "SAXParser", dependencies: ["XMLCore"]),
              .target(name: "DOMParser", dependencies: ["XMLCore", "SAXParser"]),
              .target(name: "XPath", dependencies: ["XMLCore", "DOMParser"]),

              .plugin(name: "XMLTSPlugin",
                      capability: .command(intent: .custom(verb: "xmlts",
                                                           description: "Fetch and verify the W3C XMLTS artifact"),
                                           permissions: [
                                             .writeToPackageDirectory(reason: "Extracts and refreshes XMLTS test artifacts under Tests/xmlts20130923")
                                           ])),
              .testTarget(name: "ConformanceTests", dependencies: ["XMLCore", "SAXParser"]),
              .testTarget(name: "SAXParserTests", dependencies: ["XMLCore", "SAXParser"]),
              .testTarget(name: "DOMParserTests", dependencies: ["XMLCore", "DOMParser"]),
              .testTarget(name: "XPathTests", dependencies: ["XMLCore", "DOMParser", "XPath"]),
            ])

#if !os(Windows)
  let benchmarks = ProcessInfo.processInfo.environment["XYLEM_BENCHMARKS"] == nil ? false : true
  if benchmarks {
    xylem.dependencies.append(contentsOf: [
      .package(url: "https://github.com/ordo-one/package-benchmark", exact: "1.28.0")
    ])
    xylem.targets.append(contentsOf: [
      .executableTarget(name: "SAXParserBenchmark",
                        dependencies: [
                          "XMLCore",
                          "SAXParser",
                          .product(name: "Benchmark", package: "package-benchmark"),
                        ],
                        path: "Benchmarks/SAXParserBenchmark",
                        plugins: [
                          .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
                        ]),
      .executableTarget(name: "DOMParserBenchmark",
                        dependencies: [
                          "XMLCore",
                          "SAXParser",
                          "DOMParser",
                          .product(name: "Benchmark", package: "package-benchmark"),
                        ],
                        path: "Benchmarks/DOMParserBenchmark",
                        plugins: [
                          .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
                        ]),
      .executableTarget(name: "XPathBenchmark",
                        dependencies: [
                          "XMLCore",
                          "DOMParser",
                          "XPath",
                          .product(name: "Benchmark", package: "package-benchmark"),
                        ],
                        path: "Benchmarks/XPathBenchmark",
                        plugins: [
                          .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
                        ]),
    ])
  }
#endif

for target in xylem.targets where !["XMLTSPlugin"].contains(target.name) {
  let settings: [SwiftSetting] = [
    .enableExperimentalFeature("InternalImportsByDefault"),
    .enableExperimentalFeature("Lifetimes"),
  ] + (target.name.hasSuffix("Benchmark")
          ? [.unsafeFlags(["-cross-module-optimization"])]
          : [])
  target.swiftSettings = (target.swiftSettings ?? []) + settings
}
