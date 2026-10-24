/// 从 [text] 开头截 [limit] 个 UTF-16 码元，**绝不切出落单的代理项**。
///
/// 这一句看着多余，其实是最容易漏的一处：Dart 的 `String` 是 UTF-16，
/// emoji、星平面汉字（𠮷 那类）一个字符占两个码元。按索引硬切，切点落在中间
/// 就会留下一个孤零零的高位代理——**它序列化成 JSON 是非法字符**，有些平台
/// 直接回 400，而报错里一个字都不会提"是你截断截坏的"。
///
/// 平时看不出来：切点正好压在一个 emoji 上才会触发，而且只在长输出上触发。
/// 所以判断写在一个地方，谁截都走这个函数。
///
/// [limit] 非正数返回空串（调用方要"不限"就自己判，别指望这儿）。
String clipAtCodeUnit(String text, int limit) {
  if (limit <= 0) return '';
  if (text.length <= limit) return text;

  var cut = limit;
  final last = text.codeUnitAt(cut - 1);
  // 0xD800-0xDBFF 是高位代理（一个字符的前半个）。它正好压在切点上，
  // 就把这半个让出去，少切一个码元。
  if (last >= 0xD800 && last <= 0xDBFF) cut -= 1;
  return text.substring(0, cut);
}
