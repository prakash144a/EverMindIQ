import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens.dart';
import '../../data/auth.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/initials_avatar.dart';
import '../../widgets/states.dart';
import 'delete_account_screen.dart';

/// Name, email, and what the account is for.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  Future<void> _rename(BuildContext context, WidgetRef ref, UserProfile profile) async {
    final controller = TextEditingController(text: profile.preferredName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('What should we call you?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Prakash Annadurai'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await ref.read(apiClientProvider).patchProfile(preferredName: name);
    ref.invalidate(profileProvider);
  }

  /// Hand the device back to whoever picks it up next.
  ///
  /// Confirmed first, because on a phone with one user it is a step backwards —
  /// and because the memories are the point, the dialog says plainly that they
  /// are not what is being left behind.
  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Your memories stay in your account. Sign in with your email again — '
          'here or on another device — to open them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(authControllerProvider.notifier).signOut();
    // The gate swaps in the login screen underneath; this screen and whatever
    // else is stacked on it belong to an account nobody is signed in to.
    if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(profileProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Your account')),
      body: profile.when(
        loading: () => const AppLoadingCard(),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: AppErrorCard('Could not load your profile: $e'),
        ),
        data: (p) => ListView(
          padding: const EdgeInsets.all(Insets.lg),
          children: [
            Center(child: InitialsAvatar(initials: p.initials, size: 88)),
            const SizedBox(height: Insets.lg),
            Center(
              child: Text(
                p.preferredName.isEmpty ? 'No name yet' : p.preferredName,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            if (p.email.isNotEmpty) ...[
              const SizedBox(height: Insets.xs),
              Center(
                child: Text(p.email, style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            ],
            const SizedBox(height: Insets.xl),
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Preferred name'),
              subtitle: Text(p.preferredName.isEmpty ? 'Not set' : p.preferredName),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _rename(context, ref, p),
            ),
            ListTile(
              leading: Icon(
                p.emailVerified ? Icons.verified_outlined : Icons.mail_outline,
                color: p.emailVerified ? scheme.primary : null,
              ),
              title: const Text('Email'),
              subtitle: Text(p.email.isEmpty ? 'Not linked' : p.email),
            ),
            const SizedBox(height: Insets.lg),
            Text(
              'Your memories are tied to this email, not to this phone. Sign in '
              'with it on any device to open them there — one device at a time.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Insets.xl),
            const Divider(),
            // The other half of "one device at a time": this is how a shared
            // phone gets handed to the next person.
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Sign out'),
              subtitle: const Text('Leave this device; your memories stay in your account'),
              onTap: () => _signOut(context, ref),
            ),
            // Last, and visually apart. Closing the account is not a setting to
            // be browsed past — it belongs at the end of the account screen,
            // where someone looking for it will find it and nobody else will
            // meet it on the way to something they wanted.
            ListTile(
              leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
              title: Text('Delete account', style: TextStyle(color: scheme.error)),
              subtitle: const Text('Erase every memory, permanently'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DeleteAccountScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
