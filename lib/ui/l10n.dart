import 'package:flutter/material.dart';

/// Simple localization without code generation.
/// Access via S.of(context).propertyName.
class S {
  final Locale locale;
  S(this.locale);

  static S of(BuildContext context) {
    return Localizations.of<S>(context, S) ?? S(const Locale('en'));
  }

  static const _en = _En();
  static const _zh = _Zh();

  _Strings get _strings {
    if (locale.languageCode == 'zh') return _zh;
    return _en;
  }

  // ---- Navigation ----
  String get chats => _strings.chats;
  String get people => _strings.people;
  String get me => _strings.me;

  // ---- Common ----
  String get cancel => _strings.cancel;
  String get create => _strings.create;
  String get delete => _strings.delete;
  String get save => _strings.save;
  String get close => _strings.close;
  String get failed => _strings.failed;
  String get saved => _strings.saved;
  String get copied => _strings.copied;
  String get replace => _strings.replace;
  String get later => _strings.later;
  String get match => _strings.match;
  String get verify => _strings.verify;
  String get leave => _strings.leave;
  String get accept => _strings.accept;
  String get reject => _strings.reject;

  // ---- Onboarding ----
  String get localWifiChat => _strings.localWifiChat;
  String get displayName => _strings.displayName;
  String get nameHint => _strings.nameHint;
  String get status => _strings.status;
  String get start => _strings.start;
  String get starting => _strings.starting;
  String get enterName => _strings.enterName;
  String get couldNotStart => _strings.couldNotStart;
  String get alreadyHaveAccount => _strings.alreadyHaveAccount;

  // ---- Chats ----
  String get noChats => _strings.noChats;
  String get goToPeople => _strings.goToPeople;
  String get sayHello => _strings.sayHello;
  String get noMessages => _strings.noMessages;
  String get typeMessage => _strings.typeMessage;
  String get encrypted => _strings.encrypted;
  String get delivered => _strings.delivered;
  String get sending => _strings.sending;

  // ---- People ----
  String get noPeers => _strings.noPeers;
  String get sameWifi => _strings.sameWifi;
  String get nearby => _strings.nearby;
  String get matchCode => _strings.matchCode;

  // ---- Me ----
  String get editProfile => _strings.editProfile;
  String get profile => _strings.profile;
  String get linkDevice => _strings.linkDevice;
  String get showQrToLink => _strings.showQrToLink;
  String get importAccount => _strings.importAccount;
  String get scanQrFromOther => _strings.scanQrFromOther;
  String get exportToFile => _strings.exportToFile;
  String get importFromFile => _strings.importFromFile;
  String get factoryReset => _strings.factoryReset;
  String get factoryResetConfirm => _strings.factoryResetConfirm;
  String get resetEverything => _strings.resetEverything;
  String get replaceAccount => _strings.replaceAccount;
  String get replaceAccountConfirm => _strings.replaceAccountConfirm;
  String get about => _strings.about;
  String get version => _strings.version;

  // ---- QR ----
  String get scanThisQr => _strings.scanThisQr;
  String get passcode => _strings.passcode;
  String get enterPasscodeOnNew => _strings.enterPasscodeOnNew;
  String get enterPasscode8 => _strings.enterPasscode8;
  String get pointCamera => _strings.pointCamera;
  String get qrScanned => _strings.qrScanned;
  String get scanAgain => _strings.scanAgain;
  String get accountImported => _strings.accountImported;
  String get wrongPasscode => _strings.wrongPasscode;

  // ---- Groups ----
  String get newGroup => _strings.newGroup;
  String get groupName => _strings.groupName;
  String get members => _strings.members;
  String get enterGroupName => _strings.enterGroupName;
  String get selectMembers => _strings.selectMembers;
  String get groupEncrypted => _strings.groupEncrypted;
  String get leaveGroup => _strings.leaveGroup;
  String get leaveGroupConfirm => _strings.leaveGroupConfirm;
}

abstract class _Strings {
  String get chats;
  String get people;
  String get me;
  String get cancel;
  String get create;
  String get delete;
  String get save;
  String get close;
  String get failed;
  String get saved;
  String get copied;
  String get replace;
  String get later;
  String get match;
  String get verify;
  String get leave;
  String get accept;
  String get reject;
  String get localWifiChat;
  String get displayName;
  String get nameHint;
  String get status;
  String get start;
  String get starting;
  String get enterName;
  String get couldNotStart;
  String get alreadyHaveAccount;
  String get noChats;
  String get goToPeople;
  String get sayHello;
  String get noMessages;
  String get typeMessage;
  String get encrypted;
  String get delivered;
  String get sending;
  String get noPeers;
  String get sameWifi;
  String get nearby;
  String get matchCode;
  String get editProfile;
  String get profile;
  String get linkDevice;
  String get showQrToLink;
  String get importAccount;
  String get scanQrFromOther;
  String get exportToFile;
  String get importFromFile;
  String get factoryReset;
  String get factoryResetConfirm;
  String get resetEverything;
  String get replaceAccount;
  String get replaceAccountConfirm;
  String get about;
  String get version;
  String get scanThisQr;
  String get passcode;
  String get enterPasscodeOnNew;
  String get enterPasscode8;
  String get pointCamera;
  String get qrScanned;
  String get scanAgain;
  String get accountImported;
  String get wrongPasscode;
  String get newGroup;
  String get groupName;
  String get members;
  String get enterGroupName;
  String get selectMembers;
  String get groupEncrypted;
  String get leaveGroup;
  String get leaveGroupConfirm;
}

class _En implements _Strings {
  const _En();
  @override final chats = 'Chats';
  @override final people = 'People';
  @override final me = 'Me';
  @override final cancel = 'Cancel';
  @override final create = 'Create';
  @override final delete = 'Delete';
  @override final save = 'Save';
  @override final close = 'Close';
  @override final failed = 'Failed';
  @override final saved = 'Saved';
  @override final copied = 'Copied';
  @override final replace = 'Replace';
  @override final later = 'Later';
  @override final match = 'Match';
  @override final verify = 'Verify';
  @override final leave = 'Leave';
  @override final accept = 'Accept';
  @override final reject = 'Reject';
  @override final localWifiChat = 'Local WiFi chat';
  @override final displayName = 'Display name';
  @override final nameHint = 'e.g. Alex';
  @override final status = 'Status';
  @override final start = 'Start';
  @override final starting = 'Starting…';
  @override final enterName = 'Enter a display name.';
  @override final couldNotStart = 'Could not start.';
  @override final alreadyHaveAccount = 'Already have an account? Import';
  @override final noChats = 'No chats yet';
  @override final goToPeople = 'Go to People to find devices.';
  @override final sayHello = 'Say hello.';
  @override final noMessages = 'No messages yet';
  @override final typeMessage = 'Type a message…';
  @override final encrypted = 'End-to-end encrypted';
  @override final delivered = 'Delivered';
  @override final sending = 'Sending…';
  @override final noPeers = 'No peers found';
  @override final sameWifi = 'Make sure both devices are on the same WiFi.';
  @override final nearby = 'Nearby';
  @override final matchCode = 'Check that this code matches on both devices, then tap Match.';
  @override final editProfile = 'Edit profile';
  @override final profile = 'Profile';
  @override final linkDevice = 'Link another device';
  @override final showQrToLink = 'Show QR code to link a second device';
  @override final importAccount = 'Import account';
  @override final scanQrFromOther = 'Scan QR from another device';
  @override final exportToFile = 'Export to file';
  @override final importFromFile = 'Import from file';
  @override final factoryReset = 'Factory reset';
  @override final factoryResetConfirm = 'This will delete ALL data: messages, contacts, groups. This cannot be undone.';
  @override final resetEverything = 'Reset everything';
  @override final replaceAccount = 'Replace account?';
  @override final replaceAccountConfirm = 'This will replace your current account. Continue?';
  @override final about = 'About';
  @override final version = 'Version';
  @override final scanThisQr = 'Scan this QR code on your new device';
  @override final passcode = 'Passcode';
  @override final enterPasscodeOnNew = 'Enter this passcode on the new device after scanning.';
  @override final enterPasscode8 = 'Enter the 8-character passcode.';
  @override final pointCamera = 'Point your camera at the QR code on your other device.';
  @override final qrScanned = 'QR code scanned';
  @override final scanAgain = 'Scan again';
  @override final accountImported = 'Account imported! Device linked.';
  @override final wrongPasscode = 'Wrong passcode or corrupted QR.';
  @override final newGroup = 'New group';
  @override final groupName = 'Group name';
  @override final members = 'members';
  @override final enterGroupName = 'Enter a group name.';
  @override final selectMembers = 'Select at least one member.';
  @override final groupEncrypted = 'Group encrypted';
  @override final leaveGroup = 'Leave group';
  @override final leaveGroupConfirm = 'You will no longer receive messages from this group.';
}

class _Zh implements _Strings {
  const _Zh();
  @override final chats = '聊天';
  @override final people = '联系人';
  @override final me = '我的';
  @override final cancel = '取消';
  @override final create = '创建';
  @override final delete = '删除';
  @override final save = '保存';
  @override final close = '关闭';
  @override final failed = '失败';
  @override final saved = '已保存';
  @override final copied = '已复制';
  @override final replace = '替换';
  @override final later = '稍后';
  @override final match = '匹配';
  @override final verify = '验证';
  @override final leave = '离开';
  @override final accept = '接受';
  @override final reject = '拒绝';
  @override final localWifiChat = '本地WiFi聊天';
  @override final displayName = '显示名称';
  @override final nameHint = '例如：小明';
  @override final status = '状态';
  @override final start = '开始';
  @override final starting = '启动中…';
  @override final enterName = '请输入显示名称。';
  @override final couldNotStart = '无法启动。';
  @override final alreadyHaveAccount = '已有账户？导入';
  @override final noChats = '暂无聊天';
  @override final goToPeople = '前往联系人页面查找设备。';
  @override final sayHello = '打个招呼吧。';
  @override final noMessages = '暂无消息';
  @override final typeMessage = '输入消息…';
  @override final encrypted = '端到端加密';
  @override final delivered = '已送达';
  @override final sending = '发送中…';
  @override final noPeers = '未发现设备';
  @override final sameWifi = '请确保两台设备连接同一个WiFi。';
  @override final nearby = '附近';
  @override final matchCode = '请确认两台设备上的代码一致，然后点击匹配。';
  @override final editProfile = '编辑资料';
  @override final profile = '个人资料';
  @override final linkDevice = '链接另一台设备';
  @override final showQrToLink = '显示二维码以链接第二台设备';
  @override final importAccount = '导入账户';
  @override final scanQrFromOther = '扫描另一台设备的二维码';
  @override final exportToFile = '导出到文件';
  @override final importFromFile = '从文件导入';
  @override final factoryReset = '恢复出厂设置';
  @override final factoryResetConfirm = '这将删除所有数据：消息、联系人、群组。此操作无法撤销。';
  @override final resetEverything = '重置所有内容';
  @override final replaceAccount = '替换账户？';
  @override final replaceAccountConfirm = '这将替换您当前的账户。是否继续？';
  @override final about = '关于';
  @override final version = '版本';
  @override final scanThisQr = '在新设备上扫描此二维码';
  @override final passcode = '密码';
  @override final enterPasscodeOnNew = '扫描后在新设备上输入此密码。';
  @override final enterPasscode8 = '请输入8位密码。';
  @override final pointCamera = '将摄像头对准另一台设备上的二维码。';
  @override final qrScanned = '二维码已扫描';
  @override final scanAgain = '重新扫描';
  @override final accountImported = '账户已导入！设备已链接。';
  @override final wrongPasscode = '密码错误或二维码已损坏。';
  @override final newGroup = '新建群组';
  @override final groupName = '群组名称';
  @override final members = '成员';
  @override final enterGroupName = '请输入群组名称。';
  @override final selectMembers = '请至少选择一位成员。';
  @override final groupEncrypted = '群组加密';
  @override final leaveGroup = '离开群组';
  @override final leaveGroupConfirm = '您将不再收到此群组的消息。';
}

/// Localization delegate.
class SDelegate extends LocalizationsDelegate<S> {
  const SDelegate();
  @override bool isSupported(Locale locale) => ['en', 'zh'].contains(locale.languageCode);
  @override Future<S> load(Locale locale) async => S(locale);
  @override bool shouldReload(SDelegate old) => false;
}
