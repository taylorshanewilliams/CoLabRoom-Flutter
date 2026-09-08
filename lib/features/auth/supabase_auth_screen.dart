import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/beta_config.dart';
import '../../app/colabroom_theme.dart';
import '../../widgets/app_surface.dart';
import '../../widgets/brand_mark.dart';

class SupabaseAuthScreen extends StatefulWidget {
  const SupabaseAuthScreen({required this.client, super.key});

  final SupabaseClient client;

  @override
  State<SupabaseAuthScreen> createState() => _SupabaseAuthScreenState();
}

class _SupabaseAuthScreenState extends State<SupabaseAuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _createAccount = false;
  bool _busy = false;
  bool _hidePassword = true;

  /// Old enough, and agreed to the rules.
  ///
  /// **Required before an account exists, not after.** This app is people
  /// sending each other unreviewed audio, which makes it exactly the kind of
  /// app both stores look hardest at: App Store 1.2 wants the person to have
  /// agreed there is no tolerance for objectionable content before they can
  /// post any, and an app that lets under-13s sign up in the United States is
  /// a COPPA problem rather than a policy one.
  ///
  /// One box for both, because two boxes get the same single tap and only the
  /// first one gets read. The age it names is 13 — the floor in the US; the
  /// terms carry the higher one where local law sets it.
  bool _agreed = false;

  static final Uri _terms = Uri.parse('https://colabroom.com/terms.html');
  static final Uri _privacy = Uri.parse('https://colabroom.com/privacy.html');

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_createAccount && !_agreed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please confirm your age and agree to the terms.'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      if (_createAccount) {
        final response = await widget.client.auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          // Recorded where it happened. Agreement kept only in the client is
          // an agreement nobody can show anybody afterwards, and these land
          // on the auth row with its own creation timestamp.
          data: <String, dynamic>{
            'display_name': _name.text.trim(),
            'agreed_to_terms': true,
            'age_confirmed_13': true,
          },
          emailRedirectTo: BetaConfig.authRedirectUrl.isEmpty ? null : BetaConfig.authRedirectUrl,
        );
        if (response.session == null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Check your email to confirm the account, then sign in.')),
          );
          setState(() => _createAccount = false);
        }
      } else {
        await widget.client.auth.signInWithPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
      }
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Something went wrong. Check your connection and try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your email first.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.client.auth.resetPasswordForEmail(
        email,
        redirectTo: BetaConfig.authRedirectUrl.isEmpty ? null : BetaConfig.authRedirectUrl,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password reset email sent.')),
        );
      }
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Center(child: BrandMark()),
                  const SizedBox(height: 32),
                  Text(
                    _createAccount ? 'Create your account' : 'Welcome back',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _createAccount
                        ? 'Start a private room and invite your collaborators.'
                        : 'Your rooms and songs stay in sync across every device.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  AppSurface(
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          if (_createAccount) ...<Widget>[
                            TextFormField(
                              controller: _name,
                              textCapitalization: TextCapitalization.words,
                              autofillHints: const <String>[AutofillHints.name],
                              decoration: const InputDecoration(labelText: 'Display name'),
                              validator: (value) {
                                if ((value ?? '').trim().isEmpty) return 'Enter your name.';
                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextFormField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const <String>[AutofillHints.email],
                            autocorrect: false,
                            decoration: const InputDecoration(labelText: 'Email'),
                            validator: (value) {
                              final email = (value ?? '').trim();
                              if (!email.contains('@') || !email.contains('.')) {
                                return 'Enter a valid email.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _password,
                            obscureText: _hidePassword,
                            autofillHints: <String>[
                              _createAccount ? AutofillHints.newPassword : AutofillHints.password,
                            ],
                            decoration: InputDecoration(
                              labelText: 'Password',
                              suffixIcon: IconButton(
                                tooltip: _hidePassword ? 'Show password' : 'Hide password',
                                onPressed: () => setState(() => _hidePassword = !_hidePassword),
                                icon: Icon(
                                  _hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                            validator: (value) {
                              if ((value ?? '').length < 8) return 'Use at least 8 characters.';
                              return null;
                            },
                            onFieldSubmitted: (_) => _busy ? null : _submit(),
                          ),
                          const SizedBox(height: 18),
                          if (_createAccount) _Agreement(
                            agreed: _agreed,
                            onChanged: (value) =>
                                setState(() => _agreed = value ?? false),
                            onOpen: (uri) => unawaited(
                                launchUrl(uri, mode: LaunchMode.externalApplication)),
                            terms: _terms,
                            privacy: _privacy,
                          ),
                          FilledButton(
                            onPressed: _busy ? null : _submit,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              child: _busy
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : Text(_createAccount ? 'Create Account' : 'Sign In'),
                            ),
                          ),
                          if (!_createAccount)
                            TextButton(
                              onPressed: _busy ? null : _forgotPassword,
                              child: const Text('Forgot password?'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _createAccount = !_createAccount),
                    child: Text(
                      _createAccount
                          ? 'Already have an account? Sign in'
                          : 'New to CoLabRoom? Create an account',
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Private rooms · Traceable contributions',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SupabasePasswordRecoveryScreen extends StatefulWidget {
  const SupabasePasswordRecoveryScreen({
    required this.client,
    required this.onComplete,
    super.key,
  });

  final SupabaseClient client;
  final VoidCallback onComplete;

  @override
  State<SupabasePasswordRecoveryScreen> createState() =>
      _SupabasePasswordRecoveryScreenState();
}

class _SupabasePasswordRecoveryScreenState extends State<SupabasePasswordRecoveryScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_password.text.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Use at least 8 characters.')),
      );
      return;
    }
    if (_password.text != _confirm.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The passwords do not match.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.client.auth.updateUser(UserAttributes(password: _password.text));
      widget.onComplete();
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: AppSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Center(child: BrandMark()),
                    const SizedBox(height: 24),
                    Text('Choose a new password', style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'New password'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirm,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Confirm password'),
                      onSubmitted: (_) => _busy ? null : _save(),
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: _busy ? null : _save,
                      child: const Text('Save Password'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


/// The one box somebody has to tick before an account exists.
///
/// Written as a sentence rather than a wall: an agreement nobody reads is
/// worth nothing legally and less than nothing ethically, so this says the
/// three things that actually matter — how old you have to be, that there is
/// no tolerance for abusive content or behaviour, and where the full text
/// lives — in the space somebody will actually read.
class _Agreement extends StatelessWidget {
  const _Agreement({
    required this.agreed,
    required this.onChanged,
    required this.onOpen,
    required this.terms,
    required this.privacy,
  });

  final bool agreed;
  final ValueChanged<bool?> onChanged;
  final ValueChanged<Uri> onOpen;
  final Uri terms;
  final Uri privacy;

  @override
  Widget build(BuildContext context) {
    final link = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Checkbox(
            key: const Key('auth_agree'),
            value: agreed,
            onChanged: onChanged,
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 11),
              child: Text.rich(
                TextSpan(
                  style: const TextStyle(fontSize: 12.5, height: 1.45),
                  children: <InlineSpan>[
                    const TextSpan(
                      text: 'I am 13 or older, and I agree to the ',
                    ),
                    TextSpan(
                      text: 'Terms',
                      style: link,
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => onOpen(terms),
                    ),
                    const TextSpan(text: ' and '),
                    TextSpan(
                      text: 'Privacy Policy',
                      style: link,
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => onOpen(privacy),
                    ),
                    const TextSpan(
                      text: ', including that abusive or objectionable '
                          'content is not tolerated here.',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
