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
  String get ptt => _strings.ptt;
  String get selectPeer => _strings.selectPeer;
  String get selectPeerAbove => _strings.selectPeerAbove;
  String get holdToTalk => _strings.holdToTalk;
  String get releaseToStop => _strings.releaseToStop;
  String get transmitting => _strings.transmitting;
  String get receivingFrom => _strings.receivingFrom;
  String get micPermissionRequired => _strings.micPermissionRequired;
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
  String get ptt;
  String get selectPeer;
  String get selectPeerAbove;
  String get holdToTalk;
  String get releaseToStop;
  String get transmitting;
  String get receivingFrom;
  String get micPermissionRequired;
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
  @override final failed = 'Something went wrong';
  @override final saved = 'Saved';
  @override final copied = 'Copied';
  @override final replace = 'Replace';
  @override final later = 'Later';
  @override final match = 'They match';
  @override final verify = 'Verify';
  @override final leave = 'Leave';
  @override final accept = 'Accept';
  @override final reject = 'Reject';
  @override final localWifiChat = 'Chat nearby';
  @override final displayName = 'Your name';
  @override final nameHint = 'e.g. Alex';
  @override final status = 'Status';
  @override final start = 'Get started';
  @override final starting = 'Starting…';
  @override final enterName = 'Please enter your name.';
  @override final couldNotStart = 'Could not start. Please try again.';
  @override final alreadyHaveAccount = 'Already have an account? Tap here';
  @override final noChats = 'No chats yet';
  @override final goToPeople = 'Tap "People" below to find nearby devices';
  @override final sayHello = 'Say hello!';
  @override final noMessages = 'No messages yet';
  @override final typeMessage = 'Say something…';
  @override final encrypted = 'Messages are secure — only you two can read them';
  @override final delivered = 'Delivered';
  @override final sending = 'Sending…';
  @override final noPeers = 'Nobody nearby yet';
  @override final sameWifi = 'Both phones need to be on the same WiFi';
  @override final nearby = 'Nearby';
  @override final matchCode = 'Check if the numbers look the same on both phones, then tap "They match"';
  @override final editProfile = 'Change name';
  @override final profile = 'My info';
  @override final linkDevice = 'Add another phone';
  @override final showQrToLink = 'Show this QR code to your new phone';
  @override final importAccount = 'Import account';
  @override final scanQrFromOther = 'Scan your old phone to move your account';
  @override final exportToFile = 'Back up account';
  @override final importFromFile = 'Restore from backup';
  @override final factoryReset = 'Start over';
  @override final factoryResetConfirm = 'This erases all your chats and contacts. You cannot undo this. Are you sure?';
  @override final resetEverything = 'Yes, erase everything';
  @override final replaceAccount = 'Switch accounts?';
  @override final replaceAccountConfirm = 'Your current account will be replaced. Continue?';
  @override final about = 'About Lantern';
  @override final version = 'Version';
  @override final scanThisQr = 'Scan this with your new phone';
  @override final passcode = 'Passcode';
  @override final enterPasscodeOnNew = 'Type this passcode on your new phone after scanning.';
  @override final enterPasscode8 = 'Enter the 8-character passcode.';
  @override final pointCamera = 'Point your camera at the QR code on the other phone.';
  @override final qrScanned = 'QR code scanned!';
  @override final scanAgain = 'Scan again';
  @override final accountImported = 'Done! Your account is now on this phone too.';
  @override final wrongPasscode = 'Wrong passcode. Try again.';
  @override final newGroup = 'New group';
  @override final groupName = 'Group name';
  @override final members = 'people';
  @override final enterGroupName = 'Give your group a name.';
  @override final selectMembers = 'Pick at least one person.';
  @override final groupEncrypted = 'Group messages are secure';
  @override final leaveGroup = 'Leave group';
  @override final leaveGroupConfirm = 'You will stop receiving messages from this group.';
  @override final ptt = 'Talk';
  @override final selectPeer = 'Pick someone';
  @override final selectPeerAbove = 'Pick someone above first';
  @override final holdToTalk = 'Hold to talk';
  @override final releaseToStop = 'Let go to send';
  @override final transmitting = 'Talking…';
  @override final receivingFrom = 'Voice from';
  @override final micPermissionRequired = 'Please allow microphone access';
}

class _Zh implements _Strings {
  const _Zh();
  @override final chats = '聊天';
  @override final people = '朋友';
  @override final me = '我';
  @override final cancel = '取消';
  @override final create = '创建';
  @override final delete = '删除';
  @override final save = '保存';
  @override final close = '关闭';
  @override final failed = '失败了';
  @override final saved = '保存好了';
  @override final copied = '复制好了';
  @override final replace = '替换';
  @override final later = '稍后';
  @override final match = '对上了';
  @override final verify = '确认身份';
  @override final leave = '退出';
  @override final accept = '接受';
  @override final reject = '拒绝';
  @override final localWifiChat = '附近聊天';
  @override final displayName = '你的名字';
  @override final nameHint = '比如：小明';
  @override final status = '状态';
  @override final start = '开始使用';
  @override final starting = '正在启动…';
  @override final enterName = '请输入你的名字。';
  @override final couldNotStart = '启动失败了，请重试。';
  @override final alreadyHaveAccount = '已有账号？点这里导入';
  @override final noChats = '还没有聊天';
  @override final goToPeople = '点下面的"朋友"找找附近的人吧';
  @override final sayHello = '打个招呼吧';
  @override final noMessages = '还没有消息';
  @override final typeMessage = '说点什么…';
  @override final encrypted = '消息已加密，只有你们能看到';
  @override final delivered = '已送达';
  @override final sending = '正在发送…';
  @override final noPeers = '还没找到附近的人';
  @override final sameWifi = '两台手机要连同一个WiFi哦';
  @override final nearby = '附近';
  @override final matchCode = '看看两台手机上的数字是否一样，一样就点"对上了"';
  @override final editProfile = '改名字';
  @override final profile = '我的信息';
  @override final linkDevice = '添加另一台手机';
  @override final showQrToLink = '给新手机扫码，就能用同一个账号';
  @override final importAccount = '导入账号';
  @override final scanQrFromOther = '用旧手机扫码，把账号搬过来';
  @override final exportToFile = '备份账号';
  @override final importFromFile = '从备份恢复';
  @override final factoryReset = '重新开始';
  @override final factoryResetConfirm = '会清空所有聊天记录和联系人，没法恢复哦。确定要重新开始吗？';
  @override final resetEverything = '确定，全部清掉';
  @override final replaceAccount = '要换账号吗？';
  @override final replaceAccountConfirm = '当前账号会被替换掉。继续吗？';
  @override final about = '关于灯笼';
  @override final version = '版本';
  @override final scanThisQr = '用新手机扫这个二维码';
  @override final passcode = '验证码';
  @override final enterPasscodeOnNew = '扫码后在新手机上输入这个验证码。';
  @override final enterPasscode8 = '请输入8位验证码。';
  @override final pointCamera = '把摄像头对准另一台手机上的二维码。';
  @override final qrScanned = '扫码成功';
  @override final scanAgain = '重新扫码';
  @override final accountImported = '账号导入成功！两台手机已连上。';
  @override final wrongPasscode = '验证码不对，或者二维码坏了。';
  @override final newGroup = '建群';
  @override final groupName = '群名';
  @override final members = '人';
  @override final enterGroupName = '给群起个名字吧。';
  @override final selectMembers = '至少选一个人加入群聊。';
  @override final groupEncrypted = '群消息已加密';
  @override final leaveGroup = '退出群聊';
  @override final leaveGroupConfirm = '退出后就收不到这个群的消息了。';
  @override final ptt = '对讲机';
  @override final selectPeer = '选个人';
  @override final selectPeerAbove = '先选上面的人';
  @override final holdToTalk = '按住说话';
  @override final releaseToStop = '松开发送';
  @override final transmitting = '正在说话…';
  @override final receivingFrom = '收到语音来自';
  @override final micPermissionRequired = '需要允许使用麦克风';
}

/// Localization delegate.
class SDelegate extends LocalizationsDelegate<S> {
  const SDelegate();
  @override bool isSupported(Locale locale) => ['en', 'zh'].contains(locale.languageCode);
  @override Future<S> load(Locale locale) async => S(locale);
  @override bool shouldReload(SDelegate old) => false;
}
