import 'dart:math';

/// 轻量 ID 生成器。
///
/// 不引 uuid 依赖：本应用所有 ID 都只在本地用，`时间戳 + 随机后缀` 就够——
/// 只要保证同一毫秒内生成多个不撞车即可（随机后缀 6 位 36 进制 ≈ 21 亿种）。
final _rand = Random();

String newId([String prefix = '']) {
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rnd = _rand.nextInt(2176782336).toRadixString(36).padLeft(6, '0');
  return prefix.isEmpty ? '$ts$rnd' : '${prefix}_$ts$rnd';
}
