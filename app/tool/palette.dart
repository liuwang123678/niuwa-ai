// 定稿用的临时脚本：把候选值打印出来实测对比度，选中的写死进 design/tokens.dart。
// 打印就是它的输出渠道，不是漏在生产代码里的调试语句。
// ignore_for_file: avoid_print
import 'package:niuwa_ai/design/oklch.dart';

const int _white = 0xFFFFFFFF;

/// 暖中性。色度 0.008 只留一点温度，不然是死灰。
int _n(double l) => Oklch.toArgb(l / 100, 0.008, 70);

int _g(double l, double c) => Oklch.toArgb(l / 100, c, 149);

void main() {
  final bgL = _n(97.8);
  final bgD = _n(21.0);

  print('亮底 ${Contrast.hex(bgL)}   暗底 ${Contrast.hex(bgD)}\n');

  print('══ 主色微调（H=149，找白字刚好过 4.5 的那一档）══');
  for (final l in [52.0, 54.0, 55.0, 56.0, 57.3]) {
    final col = _g(l, 0.133);
    print(
      '  L=$l  ${Contrast.hex(col)}   白字 ${_f(Contrast.ratio(_white, col))}',
    );
  }

  print('\n══ accent 当文字/图标用 ══');
  print('  亮底上：700 ${Contrast.hex(_g(46.9, 0.126))}  '
      '对比 ${_f(Contrast.ratio(_g(46.9, 0.126), bgL))}');
  print('  暗底上：400 ${Contrast.hex(_g(74.2, 0.122))}  '
      '对比 ${_f(Contrast.ratio(_g(74.2, 0.122), bgD))}');
  print('  暗底上：500 ${Contrast.hex(_g(64.8, 0.135))}  '
      '对比 ${_f(Contrast.ratio(_g(64.8, 0.135), bgD))}');

  print('\n══ 中性色：正文 / 次要文字 的对比度 ══');
  print('  档位  hex       压亮底  压暗底');
  for (final l in [21.0, 32.0, 39.4, 46.9, 57.3, 64.8, 74.2, 82.7, 88.1]) {
    final col = _n(l);
    print(
      '  L=$l  ${Contrast.hex(col)}   '
      '${_f(Contrast.ratio(col, bgL))}   ${_f(Contrast.ratio(col, bgD))}',
    );
  }

  print('\n══ 亮色模式语义对 ══');
  _pair('正文', _n(21.0), bgL);
  _pair('次要', _n(46.9), bgL);
  _pair('更淡', _n(57.3), bgL);
  _pair('分隔线', _n(88.1), bgL);
  _pair('错误红', Oklch.toArgb(0.55, 0.16, 28), bgL);

  print('\n══ 暗色模式语义对 ══');
  _pair('正文', _n(93.6), bgD);
  _pair('次要', _n(64.8), bgD);
  _pair('更淡', _n(57.3), bgD);
  _pair('分隔线', _n(32.0), bgD);
  _pair('错误红', Oklch.toArgb(0.68, 0.15, 25), bgD);
  _pair('卡片底', _n(25.0), bgD);

  print('\n══ 卡片里的文字（卡底不是页底）══');
  final cardL = _n(100);
  _pair('亮卡-正文', _n(21.0), cardL);
  _pair('亮卡-次要', _n(46.9), cardL);
}

void _pair(String name, int fg, int bg) => print(
  '  $name  ${Contrast.hex(fg)} 压 ${Contrast.hex(bg)} = '
  '${_f(Contrast.ratio(fg, bg))}',
);

String _f(double v) => v.toStringAsFixed(2);
