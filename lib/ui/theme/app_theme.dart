import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';

abstract final class AppTheme {
  static ThemeMode mode(String preference) => switch (preference) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static SystemUiOverlayStyle systemBars(Brightness brightness) {
    final icons = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  static ThemeData build(
    Color seed,
    Brightness brightness, {
    required bool television,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      // 手机 / 平板 / 桌面统一「淡出 + 轻微缩放」，电视只淡入淡出；
      // Android 上这套转场同时承载侧滑返回的跟手预览（见 motion.dart）。
      pageTransitionsTheme: pageTransitions(television: television),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: systemBars(brightness),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
    );
    final titled = theme.copyWith(
      appBarTheme: theme.appBarTheme.copyWith(
        titleTextStyle: theme.textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return theme.textTheme.labelMedium?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          );
        }),
      ),
    );
    return television ? _television(titled) : titled;
  }

  static ThemeData _television(ThemeData theme) {
    final colors = theme.colorScheme;
    // 电视上方向键是唯一的导航方式，焦点必须一眼可辨。以前 focused 只叠
    // 12% 的 onSurface，在已经是主色底的「播放」等实心按钮上几乎看不出
    // 颜色变化，遥控器移过去也判断不了有没有选中它。
    final focusedSide = WidgetStateProperty.resolveWith<BorderSide?>(
      (states) => states.contains(WidgetState.focused)
          ? BorderSide(color: colors.primary, width: 2)
          : null,
    );
    final button = ButtonStyle(
      overlayColor: WidgetStateProperty.resolveWith<Color?>(
        (states) => states.contains(WidgetState.focused)
            ? colors.primary.withValues(alpha: 0.3)
            : null,
      ),
      side: focusedSide,
      minimumSize: const WidgetStatePropertyAll(Size(52, 48)),
    );
    // 实心按钮额外反色：底色变 onSurface、图标/文字变 surface，再配一圈
    // 描边；无论亮色还是深色主题，聚焦前后都是明显的两种颜色。
    final filled = ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith<Color?>(
        (states) =>
            states.contains(WidgetState.focused) ? colors.onSurface : null,
      ),
      foregroundColor: WidgetStateProperty.resolveWith<Color?>(
        (states) =>
            states.contains(WidgetState.focused) ? colors.surface : null,
      ),
      overlayColor: WidgetStateProperty.resolveWith<Color?>(
        (states) =>
            states.contains(WidgetState.focused) ? Colors.transparent : null,
      ),
      side: focusedSide,
      minimumSize: const WidgetStatePropertyAll(Size(52, 48)),
    );
    return theme.copyWith(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      focusColor: colors.primary.withValues(alpha: 0.16),
      iconButtonTheme: IconButtonThemeData(style: button),
      filledButtonTheme: FilledButtonThemeData(style: filled),
      outlinedButtonTheme: OutlinedButtonThemeData(style: button),
      textButtonTheme: TextButtonThemeData(style: button),
    );
  }
}
