import '../services/api_client.dart';
import 'models.dart';

/// App-scoped connection defaults supplied by a private build definitions file.
/// This is not a Cloudflare management token or a TURN credential.
class DefaultConnection {
  const DefaultConnection({this.server = '', this.registrationCode = ''});

  const DefaultConnection.fromEnvironment()
    : server = const String.fromEnvironment(
        'DEFAULT_API_BASE_URL',
        defaultValue: Invite.defaultServer,
      ),
      registrationCode = const String.fromEnvironment(
        'DEFAULT_REGISTRATION_CODE',
      );

  final String server, registrationCode;

  String? get normalizedServer {
    if (server.trim().isEmpty) return null;
    try {
      return normalizeServer(server);
    } on FormatException {
      return null;
    }
  }

  bool get available =>
      normalizedServer != null && registrationCode.trim().isNotEmpty;

  bool isForServer(String value) {
    final bundled = normalizedServer;
    if (bundled == null) return false;
    try {
      return Uri.parse(normalizeServer(value)).origin ==
          Uri.parse(bundled).origin;
    } on FormatException {
      return false;
    }
  }

  /// Only explicit settings saves may fill an empty code for the default origin.
  /// Loading existing settings always preserves an intentionally empty code.
  String resolveCode(
    String destination,
    String supplied, {
    bool fillDefault = false,
  }) {
    final code = supplied.trim(), bundled = registrationCode.trim();
    if (bundled.isNotEmpty && code == bundled && !isForServer(destination)) {
      throw const FormatException('内置接入码仅用于默认服务；请填写这个服务自己的接入码');
    }
    if (fillDefault && code.isEmpty && available && isForServer(destination)) {
      return bundled;
    }
    return code;
  }
}
