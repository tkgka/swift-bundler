import Foundation
import ArgumentParser
import PackageModel

/// The subcommand for creating app bundles for a package.
struct BundleCommand: AsyncCommand {
  static var configuration = CommandConfiguration(
    commandName: "bundle",
    abstract: "Create an app bundle from a package."
  )

  /// Arguments in common with the run command.
  @OptionGroup
  var arguments: BundleArguments

  /// Whether to skip the build step or not.
  @Flag(
    name: .long,
    help: "Skip the build step.")
  var skipBuild = false

  /// If `true`, treat the products in the products directory as if they were built by Xcode (which is the same as universal builds by SwiftPM).
  ///
  /// Can only be `true` when ``skipBuild`` is `true`.
  @Flag(
    name: .long,
    help: .init(
      stringLiteral:
        "Treats the products in the products directory as if they were built by Xcode (which is the same as universal builds by SwiftPM)." +
        " Can only be set when `--skip-build` is supplied."
    ))
  var builtWithXcode = false

  /// Used to avoid loading configuration twice when RunCommand is used.
  static var app: (name: String, app: AppConfiguration)? // TODO: fix this weird pattern with a better config loading system

  init() {
    _arguments = OptionGroup()
  }

  init(arguments: OptionGroup<BundleArguments>, skipBuild: Bool, builtWithXcode: Bool) {
    _arguments = arguments
    self.skipBuild = skipBuild
    self.builtWithXcode = builtWithXcode
  }

  static func validateArguments(
    _ arguments: BundleArguments,
    platform: Platform,
    skipBuild: Bool,
    builtWithXcode: Bool
  ) -> Bool {
    // Validate parameters
    if !skipBuild {
      guard arguments.productsDirectory == nil, !builtWithXcode else {
        log.error("'--products-directory' and '--built-with-xcode' are only compatible with '--skip-build'")
        return false
      }
    }

    if case .iOS = platform, builtWithXcode || arguments.universal || !arguments.architectures.isEmpty {
      log.error("'--built-with-xcode', '--universal' and '--arch' are not compatible with '--platform iOS'")
      return false
    }

    if arguments.shouldCodesign && arguments.identity == nil {
      log.error("Please provide a codesigning identity with `--identity`")
      Output {
        ""
        Section("Tip: Listing available identities") {
          ExampleCommand("swift bundler list-identities")
        }
      }.show()
      return false
    }

    if arguments.identity != nil && !arguments.shouldCodesign {
      log.error("`--identity` can only be used with `--codesign`")
      return false
    }

    if case .iOS = platform, !arguments.shouldCodesign || arguments.identity == nil || arguments.provisioningProfile == nil {
      log.error("Must specify `--identity`, `--codesign` and `--provisioning-profile` when building iOS app")
      if arguments.identity == nil {
        Output {
          ""
          Section("Tip: Listing available identities") {
            ExampleCommand("swift bundler list-identities")
          }
        }.show()
      }
      return false
    }

    if platform != .macOS && arguments.standAlone {
      log.error("'--experimental-stand-alone' only works on macOS")
      return false
    }

    switch platform {
      case .iOS:
        break
      default:
        if arguments.provisioningProfile != nil {
          log.error("`--provisioning-profile` is only available when building iOS apps")
          return false
        }
    }

    return true
  }

  func getArchitectures(platform: Platform) -> [BuildArchitecture] {
    let architectures: [BuildArchitecture]
    switch platform {
      case .macOS:
        architectures = arguments.universal
          ? [.arm64, .x86_64]
          : (!arguments.architectures.isEmpty ? arguments.architectures : [BuildArchitecture.current])
      case .iOS:
        architectures = [.arm64]
      case .iOSSimulator:
        architectures = [BuildArchitecture.current]
    }

    return architectures
  }

  func wrappedRun() async throws {
    var appBundle: URL?

    // Start timing
    let elapsed = try await Stopwatch.time {
      // Load configuration
      let packageDirectory = arguments.packageDirectory ?? URL(fileURLWithPath: ".")
      let (appName, appConfiguration) = try Self.getAppConfiguration(
        arguments.appName,
        packageDirectory: packageDirectory,
        customFile: arguments.configurationFileOverride
      ).unwrap()

      if !Self.validateArguments(arguments, platform: arguments.platform, skipBuild: skipBuild, builtWithXcode: builtWithXcode) {
        Foundation.exit(1)
      }

      // Get relevant configuration
      let universal = arguments.universal || arguments.architectures.count > 1
      let architectures = getArchitectures(platform: arguments.platform)

      let outputDirectory = Self.getOutputDirectory(arguments.outputDirectory, packageDirectory: packageDirectory)

      appBundle = outputDirectory.appendingPathComponent("\(appName).app")

      // Load package manifest
      log.info("Loading package manifest")
      let manifest = try await SwiftPackageManager.loadPackageManifest(from: packageDirectory).unwrap()

      guard let platformVersion = manifest.platformVersion(for: arguments.platform) else {
        let manifestFile = packageDirectory.appendingPathComponent("Package.swift")
        throw CLIError.failedToGetPlatformVersion(platform: arguments.platform, manifest: manifestFile)
      }

      // Get build output directory
      let productsDirectory = try arguments.productsDirectory ?? SwiftPackageManager.getProductsDirectory(
        in: packageDirectory,
        configuration: arguments.buildConfiguration,
        architectures: architectures,
        platform: arguments.platform,
        platformVersion: platformVersion
      ).unwrap()

      // Create build job
      let build: () async -> Result<Void, Error> = {
        SwiftPackageManager.build(
          product: appConfiguration.product,
          packageDirectory: packageDirectory,
          configuration: arguments.buildConfiguration,
          architectures: architectures,
          platform: arguments.platform,
          platformVersion: platformVersion
        ).mapError { error in
          return error
        }
      }

      // Create bundle job
      let bundler = getBundler(for: arguments.platform)
      let bundle = {
        bundler.bundle(
          appName: appName,
          packageName: manifest.displayName,
          appConfiguration: appConfiguration,
          packageDirectory: packageDirectory,
          productsDirectory: productsDirectory,
          outputDirectory: outputDirectory,
          isXcodeBuild: builtWithXcode,
          universal: universal,
          standAlone: arguments.standAlone,
          codesigningIdentity: arguments.identity,
          provisioningProfile: arguments.provisioningProfile,
          platformVersion: platformVersion,
          targetingSimulator: arguments.platform.isSimulator
        )
      }

      // Build pipeline
      let task: () async -> Result<Void, Error>
      if skipBuild {
        task = bundle
      } else {
        task = flatten(
          build,
          bundle
        )
      }

      // Run pipeline
      try await task().unwrap()
    }

    // Output the time elapsed and app bundle location
    log.info("Done in \(elapsed.secondsString). App bundle located at '\(appBundle?.relativePath ?? "unknown")'")
  }

  /// Gets the configuration for the specified app.
  ///
  /// If no app is specified, the first app is used (unless there are multiple apps, in which case a failure is returned).
  /// - Parameters:
  ///   - appName: The app's name.
  ///   - packageDirectory: The package's root directory.
  ///   - customFile: A custom configuration file not at the standard location.
  /// - Returns: The app's configuration if successful.
  static func getAppConfiguration(
    _ appName: String?,
    packageDirectory: URL,
    customFile: URL? = nil
  ) -> Result<(name: String, app: AppConfiguration), PackageConfigurationError> {
    if let app = Self.app {
      return .success(app)
    }

    return PackageConfiguration.load(
      fromDirectory: packageDirectory,
      customFile: customFile
    ).flatMap { configuration in
      return configuration.getAppConfiguration(appName)
    }.map { app in
      Self.app = app
      return app
    }
  }

  /// Unwraps an optional output directory and returns the default output directory if it's `nil`.
  /// - Parameters:
  ///   - outputDirectory: The output directory. Returned as-is if not `nil`.
  ///   - packageDirectory: The root directory of the package.
  /// - Returns: The output directory to use.
  static func getOutputDirectory(_ outputDirectory: URL?, packageDirectory: URL) -> URL {
    return outputDirectory ?? packageDirectory.appendingPathComponent(".build/bundler")
  }
}
