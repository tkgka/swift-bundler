import Foundation

/// An error related to package configuration.
enum PackageConfigurationError: LocalizedError {
  case noSuchApp(String)
  case multipleAppsAndNoneSpecified
  case failedToEvaluateExpressions(app: String, AppConfigurationError)
  case failedToReadConfigurationFile(URL, Error)
  case failedToDeserializeConfiguration(Error)
  case failedToSerializeConfiguration(Error)
  case failedToWriteToConfigurationFile(URL, Error)
  case failedToReadContentsOfOldConfigurationFile(URL, Error)
  case failedToDeserializeOldConfiguration(Error)
  case failedToSerializeMigratedConfiguration(Error)
  case failedToWriteToMigratedConfigurationFile(URL, Error)
  case failedToCreateConfigurationBackup(Error)
  case failedToDeserializeV2Configuration(Error)

  var errorDescription: String? {
    switch self {
      case .noSuchApp(let name):
        return "There is no app called '\(name)'."
      case .multipleAppsAndNoneSpecified:
        return "This package contains multiple apps. You must provide the 'app-name' argument"
      case .failedToEvaluateExpressions(let app, let appConfigurationError):
        return "Failed to evaluate the '\(app)' app's configuration: \(appConfigurationError.localizedDescription)"
      case .failedToReadConfigurationFile(let file, _):
        return "Failed to read the configuration file at '\(file.relativePath)'. Are you sure that it exists?"
      case .failedToDeserializeConfiguration(let error):
        let deserializationError: String
        switch error {
          case DecodingError.keyNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            deserializationError = "Expected a value at '\(path)'"
          default:
            deserializationError = "Unknown cause"
        }
        return "Failed to deserialize configuration: \(deserializationError)"
      case .failedToSerializeConfiguration:
        return "Failed to serialize configuration"
      case .failedToWriteToConfigurationFile(let file, _):
        return "Failed to write to configuration file at '\(file.relativePath)"
      case .failedToDeserializeOldConfiguration(let error):
        return "Failed to deserialize old configuration: \(error.localizedDescription)"
      case .failedToReadContentsOfOldConfigurationFile(let file, _):
        return "Failed to read contents of old configuration file at '\(file.relativePath)'"
      case .failedToSerializeMigratedConfiguration:
        return "Failed to serialize migrated configuration"
      case .failedToWriteToMigratedConfigurationFile(let file, _):
        return "Failed to write migrated configuration to file at '\(file.relativePath)'"
      case .failedToCreateConfigurationBackup:
        return "Failed to backup configuration file"
      case .failedToDeserializeV2Configuration(let error):
        let deserializationError: String
        switch error {
          case DecodingError.keyNotFound(let codingKey, let context):
            if codingKey.stringValue == "bundle_identifier" {
              deserializationError = "'bundle_identifier' is required for app configuration to be migrated"
            } else {
              let path = context.codingPath.map(\.stringValue).joined(separator: ".")
              deserializationError = "Expected a value at '\(path)'"
            }
          default:
            deserializationError = "Unknown cause"
        }
        return "Failed to deserialize configuration for migration: \(deserializationError)"
    }
  }
}
