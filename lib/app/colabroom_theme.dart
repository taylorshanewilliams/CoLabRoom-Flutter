import 'package:flutter/material.dart';

abstract final class AppColors {
  static const ink = Color(0xFF030812);
  static const deepNavy = Color(0xFF06101F);
  static const surface = Color(0xFF081225);
  static const raised = Color(0xFF0C1B33);
  static const cyan = Color(0xFF3AD3FF);
  static const blue = Color(0xFF2B6FFF);
  static const text = Color(0xFFF8FBFF);
  static const muted = Color(0xFF91A0BB);
  static const line = Color(0xFF152D4E);
  static const orange = Color(0xFFFF914D);
  static const green = Color(0xFF45D6A5);
}

abstract final class CoLabRoomTheme {
  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.cyan,
      brightness: Brightness.dark,
      surface: AppColors.surface,
    ).copyWith(
      primary: AppColors.cyan,
      secondary: AppColors.blue,
      surface: AppColors.surface,
      error: const Color(0xFFFF718B),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.ink,
      canvasColor: AppColors.ink,
      textTheme: const TextTheme(
        displaySmall: TextStyle(
          color: AppColors.text,
          fontSize: 30,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.8,
        ),
        headlineMedium: TextStyle(
          color: AppColors.text,
          fontSize: 24,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.6,
        ),
        titleLarge: TextStyle(color: AppColors.text, fontWeight: FontWeight.w700),
        titleMedium: TextStyle(color: AppColors.text, fontWeight: FontWeight.w700),
        bodyLarge: TextStyle(color: AppColors.text, height: 1.4),
        bodyMedium: TextStyle(color: AppColors.muted, height: 1.4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: const TextStyle(color: AppColors.muted),
        prefixIconColor: AppColors.muted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: AppColors.cyan, width: 1.2),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppColors.raised,
        contentTextStyle: TextStyle(color: AppColors.text),
        behavior: SnackBarBehavior.floating,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        labelTextStyle: WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w700)),
      ),
      dividerColor: AppColors.line,
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: AppColors.line),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
    );
  }
}
