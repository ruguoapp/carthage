import Foundation
import Result
import ReactiveSwift
import XCDBLD

/// A map of build settings and their values, as generated by Xcode.
public struct BuildSettings {
	/// The target to which these settings apply.
	public let target: String

	/// All build settings given at initialization.
	public let settings: [String: String]

	/// The build arguments used for loading the settings.
	public let arguments: BuildArguments

	/// The designated xcodebuild action if present.
	public let action: BuildArguments.Action?

	internal init(
		target: String,
		settings: [String: String],
		arguments: BuildArguments,
		action: BuildArguments.Action?
	) {
		self.target = target
		self.settings = settings
		self.arguments = arguments
		self.action = action
	}

	/// Matches lines of the forms:
	///
	/// Build settings for action build and target "ReactiveCocoaLayout Mac":
	/// Build settings for action test and target CarthageKitTests:
	private static let targetSettingsRegex = try! NSRegularExpression( // swiftlint:disable:this force_try
		pattern: "^Build settings for action (?:\\S+) and target \\\"?([^\":]+)\\\"?:$",
		options: [ .caseInsensitive, .anchorsMatchLines ]
	)

	/// Invokes `xcodebuild` to retrieve build settings for the given build
	/// arguments.
	///
	/// Upon .success, sends one BuildSettings value for each target included in
	/// the referenced scheme.
	public static func load(with arguments: BuildArguments, for action: BuildArguments.Action? = nil) -> SignalProducer<BuildSettings, CarthageError> {
		// xcodebuild (in Xcode 8.0) has a bug where xcodebuild -showBuildSettings
		// can hang indefinitely on projects that contain core data models.
		// rdar://27052195
		// Including the action "clean" works around this issue, which is further
		// discussed here: https://forums.developer.apple.com/thread/50372
		//
		// "archive" also works around the issue above so use it to determine if
		// it is configured for the archive action.
		let task = xcodebuildTask(["archive", "-showBuildSettings", "-skipUnavailableActions"], arguments)

		return task.launch()
			.ignoreTaskData()
			.mapError(CarthageError.taskError)
			// xcodebuild has a bug where xcodebuild -showBuildSettings
			// can sometimes hang indefinitely on projects that don't
			// share any schemes, so automatically bail out if it looks
			// like that's happening.
			.timeout(after: 60, raising: .xcodebuildTimeout(arguments.project), on: QueueScheduler(qos: .default))
			.retry(upTo: 5)
			.map { data in
				return String(data: data, encoding: .utf8)!
			}
			.flatMap(.merge) { string -> SignalProducer<BuildSettings, CarthageError> in
				return SignalProducer { observer, lifetime in
					var currentSettings: [String: String] = [:]
					var currentTarget: String?

					let flushTarget = { () -> Void in
						if let currentTarget = currentTarget {
							let buildSettings = self.init(
								target: currentTarget,
								settings: currentSettings,
								arguments: arguments,
								action: action
							)
							observer.send(value: buildSettings)
						}

						currentTarget = nil
						currentSettings = [:]
					}

					string.enumerateLines { line, stop in
						if lifetime.hasEnded {
							stop = true
							return
						}

						if let result = self.targetSettingsRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
							let targetRange = Range(result.range(at: 1), in: line)!

							flushTarget()
							currentTarget = String(line[targetRange])
							return
						}

						let trimSet = CharacterSet.whitespacesAndNewlines
						let components = line
							.split(maxSplits: 1) { $0 == "=" }
							.map { $0.trimmingCharacters(in: trimSet) }

						if components.count == 2 {
							currentSettings[components[0]] = components[1]
						}
					}

					flushTarget()
					observer.sendCompleted()
				}
			}
	}

	/// Determines which SDKs the given scheme builds for, by default.
	///
	/// If an SDK is unrecognized or could not be determined, an error will be
	/// sent on the returned signal.
	public static func SDKsForScheme(_ scheme: Scheme, inProject project: ProjectLocator) -> SignalProducer<SDK, CarthageError> {
		return load(with: BuildArguments(project: project, scheme: scheme))
			.take(first: 1)
			.flatMap(.merge) { $0.buildSDKs }
	}

	/// Returns the value for the given build setting, or an error if it could
	/// not be determined.
	public subscript(key: String) -> Result<String, CarthageError> {
		if let value = settings[key] {
			return .success(value)
		} else {
			return .failure(.missingBuildSetting(key))
		}
	}

	/// Attempts to determine the SDKs this scheme builds for.
	public var buildSDKs: SignalProducer<SDK, CarthageError> {
		let supportedPlatforms = self["SUPPORTED_PLATFORMS"]

		if let supportedPlatforms = supportedPlatforms.value {
			let platforms = supportedPlatforms.split { $0 == " " }.map(String.init)
			return SignalProducer<String, CarthageError>(platforms)
				.map { platform in SignalProducer(result: SDK.from(string: platform)) }
				.flatten(.merge)
		}

		let firstBuildSDK = self["PLATFORM_NAME"].flatMap(SDK.from(string:))
		return SignalProducer(result: firstBuildSDK)
	}

	/// Attempts to determine the ProductType specified in these build settings.
	public var productType: Result<ProductType, CarthageError> {
		return self["PRODUCT_TYPE"].flatMap(ProductType.from(string:))
	}

	/// Attempts to determine the MachOType specified in these build settings.
	public var machOType: Result<MachOType, CarthageError> {
		return self["MACH_O_TYPE"].flatMap(MachOType.from(string:))
	}

	/// Attempts to determine the FrameworkType identified by these build settings.
	internal var frameworkType: Result<FrameworkType?, CarthageError> {
		return productType.fanout(machOType).map(FrameworkType.init)
	}

	/// Attempts to determine the URL to the built products directory.
	public var builtProductsDirectoryURL: Result<URL, CarthageError> {
		return self["BUILT_PRODUCTS_DIR"].map { productsDir in
			return URL(fileURLWithPath: productsDir, isDirectory: true)
		}
	}

	private var productsDirectoryURLDependingOnAction: Result<URL, CarthageError> {
		if action == .archive {
			return self["OBJROOT"]
				.fanout(archiveIntermediatesBuildProductsPath)
				.map { objroot, path -> URL in
					let root = URL(fileURLWithPath: objroot, isDirectory: true)
					return root.appendingPathComponent(path)
				}
		} else {
			return builtProductsDirectoryURL
		}
	}

	private var archiveIntermediatesBuildProductsPath: Result<String, CarthageError> {
		let r1 = self["TARGET_NAME"]
		guard let schemeOrTarget = arguments.scheme?.name ?? r1.value else { return r1 }

		let basePath = "ArchiveIntermediates/\(schemeOrTarget)/BuildProductsPath"
		let pathComponent: String

		if
			let buildDir = self["BUILD_DIR"].value,
			let builtProductsDir = self["BUILT_PRODUCTS_DIR"].value,
			builtProductsDir.hasPrefix(buildDir)
		{
			// This is required to support CocoaPods-generated projects.
			// See https://github.com/AliSoftware/Reusable/issues/50#issuecomment-336434345 for the details.
			pathComponent = String(builtProductsDir[buildDir.endIndex...]) // e.g., /Release-iphoneos/Reusable-iOS
		} else {
			let r2 = self["CONFIGURATION"]
			guard let configuration = r2.value else { return r2 }

			// A value almost certainly beginning with `-` or (lacking said value) an
			// empty string to append without effect in the path below because Xcode
			// expects the path like that.
			let effectivePlatformName = self["EFFECTIVE_PLATFORM_NAME"].value ?? ""

			// e.g.,
			// - Release
			// - Release-iphoneos
			pathComponent = "\(configuration)\(effectivePlatformName)"
		}

		let path = (basePath as NSString).appendingPathComponent(pathComponent)
		return .success(path)
	}

	/// Attempts to determine the relative path (from the build folder) to the
	/// built executable.
	public var executablePath: Result<String, CarthageError> {
		return self["EXECUTABLE_PATH"]
	}

	/// Attempts to determine the URL to the built executable, corresponding to
	/// its xcodebuild action.
	public var executableURL: Result<URL, CarthageError> {
		return productsDirectoryURLDependingOnAction
			.fanout(executablePath)
			.map { productsDirectoryURL, executablePath in
				return productsDirectoryURL.appendingPathComponent(executablePath)
			}
	}

	/// Attempts to determine the name of the built product's wrapper bundle.
	public var wrapperName: Result<String, CarthageError> {
		return self["WRAPPER_NAME"]
	}

	/// Attempts to determine the name of the built product's wrapper bundle replacing "framework" with "xcframework".
	public var xcFrameworkWrapperName: Result<String, CarthageError> {
		return self["WRAPPER_NAME"].map { $0.spm_dropSuffix(".framework").appending(".xcframework") }
	}

	/// Attempts to determine the URL to the built product's wrapper, corresponding
	/// to its xcodebuild action.
	public var wrapperURL: Result<URL, CarthageError> {
		return productsDirectoryURLDependingOnAction
			.fanout(wrapperName)
			.map { productsDirectoryURL, wrapperName in
				return productsDirectoryURL.appendingPathComponent(wrapperName)
			}
	}

	/// Attempts to determine whether bitcode is enabled or not.
	public var bitcodeEnabled: Result<Bool, CarthageError> {
		return self["ENABLE_BITCODE"].map { $0 == "YES" }
	}

	/// Attempts to determine the relative path (from the build folder) where
	/// the Swift modules for the built product will exist.
	///
	/// If the product does not build any modules, `nil` will be returned.
	internal var relativeModulesPath: Result<String?, CarthageError> {
		if let moduleName = self["PRODUCT_MODULE_NAME"].value {
			return self["CONTENTS_FOLDER_PATH"].map { contentsPath in
				let path1 = (contentsPath as NSString).appendingPathComponent("Modules")
				let path2 = (path1 as NSString).appendingPathComponent(moduleName)
				return (path2 as NSString).appendingPathExtension("swiftmodule")
			}
		} else {
			return .success(nil)
		}
	}

	/// Attempts to determine the code signing identity.
	public var codeSigningIdentity: Result<String, CarthageError> {
		return self["CODE_SIGN_IDENTITY"]
	}

	/// Attempts to determine if ad hoc code signing is allowed.
	public var adHocCodeSigningAllowed: Result<Bool, CarthageError> {
		return self["AD_HOC_CODE_SIGNING_ALLOWED"].map { $0 == "YES" }
	}

	/// Attempts to determine the path to the project that contains the current target
	public var projectPath: Result<String, CarthageError> {
		return self["PROJECT_FILE_PATH"]
	}

	/// Attempts to determine target build directory
	public var targetBuildDirectory: Result<String, CarthageError> {
		return self["TARGET_BUILD_DIR"]
	}

	/// Attepts to determine if UIKit for Mac is supported
	public var supportsUIKitForMac: Result<Bool, CarthageError> {
		self["SUPPORTS_UIKITFORMAC"].map { $0 == "YES" }
	}

	/// Add subdirectory path if it's not possible to paste product to destination path
	public func productDestinationPath(in destinationURL: URL) -> URL {
		let directoryURL: URL
		let frameworkType = self.frameworkType.value.flatMap { $0 }
		if frameworkType == .static {
			directoryURL = destinationURL.appendingPathComponent(FrameworkType.staticFolderName)
		} else {
			directoryURL = destinationURL
		}
		return directoryURL
	}
}

extension BuildSettings: CustomStringConvertible {
	public var description: String {
		return "Build settings for target \"\(target)\": \(settings)"
	}
}
