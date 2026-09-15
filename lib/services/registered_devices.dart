/// The phones registered to this account, and which one you are holding.
///
/// Taylor, 15 September 2026: two messages arrived from his tester, the push
/// sender reported `{"sent":2,"pruned":0}` for both, and his phone showed
/// nothing. `device_tokens` held two rows, both saying `android`, and there
/// was no way to learn whether either of them was the phone in his hand --
/// on this project one Android row is usually the emulator, which can never
/// draw a notification.
///
/// `my_devices` returns the last six characters of each token, which
/// identify a row without being usable as an address. The app knows its own
/// token, so it can say which row is this phone, and the sentence below can
/// say the one thing that actually matters: whether anything sent to this
/// account reaches the phone somebody is looking at.
///
/// Kept out of the widget so the wording can be pinned by a test that does
/// not need Firebase.
class RegisteredDevice {
  const RegisteredDevice({
    required this.tokenTail,
    required this.platform,
    this.firstSeenAt,
    this.lastSeenAt,
  });

  factory RegisteredDevice.fromRow(Map<String, dynamic> row) {
    DateTime? when(Object? value) =>
        value is String ? DateTime.tryParse(value)?.toLocal() : null;
    return RegisteredDevice(
      tokenTail: (row['token_tail'] as String?) ?? '',
      platform: (row['platform'] as String?) ?? '',
      firstSeenAt: when(row['first_seen_at']),
      lastSeenAt: when(row['last_seen_at']),
    );
  }

  /// The last six characters of the token. Enough to match a row against the
  /// token this install holds; not enough to send anything anywhere.
  final String tokenTail;

  /// 'ios', 'android' or 'web', as the server recorded it.
  final String platform;

  final DateTime? firstSeenAt;
  final DateTime? lastSeenAt;

  /// 'Android', 'iPhone', 'Web', or whatever the server said if it is none
  /// of those -- an unknown platform should read as itself rather than as a
  /// guess.
  String get platformName {
    switch (platform) {
      case 'android':
        return 'Android';
      case 'ios':
        return 'iPhone';
      case 'web':
        return 'Web';
      default:
        return platform.isEmpty ? 'Unknown' : platform;
    }
  }

  /// Whether this row is the device asking.
  ///
  /// Matched on the tail rather than the whole token because the whole token
  /// never leaves the server. Six characters of a token that is closer to a
  /// hundred and sixty: a collision between two of one person's own devices
  /// is not a thing worth guarding against, and the cost of one would be a
  /// wrong label rather than a wrong delivery.
  bool isThisDevice(String? myToken) {
    if (myToken == null || tokenTail.isEmpty) return false;
    return myToken.endsWith(tokenTail);
  }
}

/// The sentence the settings screen says about this account's phones.
///
/// Written so the bad case is unmissable. "Two Android devices are
/// registered, and neither is this phone" is the sentence that would have
/// saved a day of looking at the server.
String describeRegisteredDevices(
  List<RegisteredDevice> devices, {
  String? myToken,
}) {
  if (devices.isEmpty) {
    return 'No device is registered for this account, so nothing can be '
        'delivered to a phone yet.';
  }

  final mine = devices.where((d) => d.isThisDevice(myToken)).toList();
  final others = devices.where((d) => !d.isThisDevice(myToken)).toList();
  final otherNames = _countByPlatform(others);

  if (mine.isEmpty) {
    // The case worth shouting about: pushes are being accepted for devices
    // that are not the one in front of you, so nothing will ever show up here.
    final what = devices.length == 1
        ? 'One device is registered'
        : '${devices.length} devices are registered';
    return '$what for this account ($otherNames), and none of them is this '
        'one. Nothing sent to this account will show up on this phone until '
        'notifications are turned on here.';
  }

  if (others.isEmpty) {
    return 'This ${mine.first.platformName} is the only device registered, so '
        'everything sent to this account comes here.';
  }

  final also = others.length == 1
      ? 'one other device ($otherNames)'
      : '${others.length} other devices ($otherNames)';
  return 'This ${mine.first.platformName} is registered, and so is $also. '
      'Everything sent to this account goes to all of them, so a notification '
      'missing here while another device has it is this phone, not the push.';
}

/// 'Android', '2 Android', 'Android and iPhone' — named by platform, because
/// that is the only thing the server can say about a device without handing
/// out the token.
String _countByPlatform(List<RegisteredDevice> devices) {
  if (devices.isEmpty) return 'none';
  final counts = <String, int>{};
  for (final device in devices) {
    counts[device.platformName] = (counts[device.platformName] ?? 0) + 1;
  }
  final parts = <String>[
    for (final entry in counts.entries)
      entry.value == 1 ? entry.key : '${entry.value} ${entry.key}',
  ];
  if (parts.length == 1) return parts.first;
  return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
}
