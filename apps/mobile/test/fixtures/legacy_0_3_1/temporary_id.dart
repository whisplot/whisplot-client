import 'dart:math';

/// A display pseudonym. Changing it deliberately does not rotate device keys.
abstract final class TemporaryId {
  static const _alphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  static final _pattern = RegExp(r'^临时·[2-9A-HJ-NP-Z]{6}$');

  static String generate({Random? random, String? differentFrom}) {
    final source = random ?? Random.secure();
    String value;
    do {
      value =
          '临时·${List.generate(6, (_) => _alphabet[source.nextInt(_alphabet.length)]).join()}';
    } while (value == differentFrom);
    return value;
  }

  static bool isValid(String value) => _pattern.hasMatch(value);

  /// Pre-upgrade messages had no sender-name snapshot. Never substitute the
  /// sender's current profile name, because that would rewrite old history.
  static String legacy(String deviceId) {
    final stable = deviceId.length >= 6 ? deviceId.substring(0, 6) : deviceId;
    return '旧ID·${stable.toUpperCase()}';
  }
}

/// The current pseudonym and its remaining budget, never a list of past IDs.
class AliasRotationState {
  const AliasRotationState({
    required this.alias,
    this.limit = 1,
    this.used = 0,
    this.budget = 1,
  });
  static const limits = [1, 10, 50];
  final String alias;
  final int limit, used, budget;

  factory AliasRotationState.fromJson(Map<String, dynamic> json) {
    if (json['v'] != 1 ||
        json['alias'] is! String ||
        !TemporaryId.isValid(json['alias'] as String) ||
        !limits.contains(json['limit']) ||
        !limits.contains(json['budget']) ||
        json['used'] is! int ||
        (json['used'] as int) < 0 ||
        (json['used'] as int) >= 50) {
      throw const FormatException('临时ID计数状态损坏，已停止发送以避免重复使用');
    }
    return AliasRotationState(
      alias: json['alias'],
      limit: json['limit'],
      used: json['used'],
      budget: json['budget'],
    );
  }
  Map<String, dynamic> toJson() => {
    'v': 1,
    'alias': alias,
    'limit': limit,
    'used': used,
    'budget': budget,
  };

  AliasRotationState withLimit(int value) {
    if (!limits.contains(value)) {
      throw const FormatException('仅支持每1、10或50条更换临时ID');
    }
    // A used identity never gains extra capacity from repeatedly changing tiers.
    return AliasRotationState(
      alias: alias,
      limit: value,
      used: used,
      budget: used == 0 ? value : min(budget, value),
    );
  }

  ({String senderName, AliasRotationState next}) consume() {
    final current = used >= budget
        ? AliasRotationState(
            alias: TemporaryId.generate(differentFrom: alias),
            limit: limit,
            budget: limit,
          )
        : this;
    final nextUsed = current.used + 1;
    final next = nextUsed >= current.budget
        ? AliasRotationState(
            alias: TemporaryId.generate(differentFrom: current.alias),
            limit: limit,
            budget: limit,
          )
        : AliasRotationState(
            alias: current.alias,
            limit: limit,
            used: nextUsed,
            budget: current.budget,
          );
    return (senderName: current.alias, next: next);
  }
}
