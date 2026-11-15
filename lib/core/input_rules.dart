import 'package:flutter/services.dart';

String sanitizeText(String value, {bool collapseSpaces = false}) {
  var result = value
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), '')
      .replaceAll(RegExp(r'[\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u206F\uFEFF]'), '');
  if (collapseSpaces) result = result.replaceAll(RegExp(r'\s+'), ' ');
  return result.trim();
}

String? canonicalPhone(String value) {
  final compact = sanitizeText(value).replaceAll(RegExp(r'[\s-]'), '');
  if (RegExp(r'^07\d{8}$').hasMatch(compact)) {
    return '+94${compact.substring(1)}';
  }
  if (RegExp(r'^7\d{8}$').hasMatch(compact)) return '+94$compact';
  if (RegExp(r'^\+947\d{8}$').hasMatch(compact)) return compact;
  return null;
}

String authIdentifier(String phoneOrEmail) {
  final phone = canonicalPhone(phoneOrEmail);
  if (phone != null) return '$phone@rideguard.app';
  return sanitizeText(phoneOrEmail).toLowerCase();
}

String? fullNameError(String value) {
  final name = sanitizeText(value, collapseSpaces: true);
  if (name.length < 2 || name.length > 60) return 'Enter a valid full name.';
  if (!RegExp(r"^[\p{L}\p{M} .'-]+$", unicode: true).hasMatch(name)) {
    return 'Use letters, spaces, dots, apostrophes, or hyphens only.';
  }
  return null;
}

String? emailError(String value) {
  final email = sanitizeText(value).toLowerCase();
  if (email.length > 254 ||
      !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
    return 'Enter a valid email address.';
  }
  return null;
}

String? phoneError(String value) =>
    canonicalPhone(value) == null ? 'Enter a valid phone number.' : null;

String? normalizeNic(String value) {
  final normalized = sanitizeText(value).replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
  if (!RegExp(r'^(\d{9}[VX]|\d{12})$').hasMatch(normalized)) return null;
  return normalized;
}

String? nicError(String value) => normalizeNic(value) == null
    ? 'Enter a valid NIC number (for example 912345678V or 199112345678).'
    : null;

String maskNic(String value) {
  final normalized = normalizeNic(value) ?? value.trim().toUpperCase();
  return normalized.length < 3
      ? '***'
      : '${List.filled(normalized.length - 3, '*').join()}'
          '${normalized.substring(normalized.length - 3)}';
}

class NicInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final value = newValue.text
        .replaceAll(RegExp(r'[\s-]'), '')
        .toUpperCase();
    return TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }
}
