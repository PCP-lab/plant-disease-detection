// Auth state providers and sign-in actions.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../config.dart';

/// Always null in prototype mode (no Firebase).
final authStateProvider = StreamProvider<User?>(
  (ref) => ref.watch(firebaseEnabledProvider)
      ? FirebaseAuth.instance.authStateChanges()
      : Stream.value(null),
);

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

class AuthService {
  FirebaseAuth get _auth => FirebaseAuth.instance;

  bool _googleInitialized = false;

  Future<void> signInWithEmail(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email, password: password);

  Future<void> registerWithEmail(String email, String password) =>
      _auth.createUserWithEmailAndPassword(email: email, password: password);

  Future<void> sendPasswordReset(String email) =>
      _auth.sendPasswordResetEmail(email: email);

  /// Returns false if the user closed the Google dialog.
  Future<bool> signInWithGoogle() async {
    if (kIsWeb) {
      await _auth.signInWithPopup(GoogleAuthProvider());
      return true;
    }

    final google = GoogleSignIn.instance;
    if (!_googleInitialized) {
      await google.initialize(
        clientId: googleIosClientId.isEmpty ? null : googleIosClientId,
        serverClientId: googleServerClientId.isEmpty
            ? null
            : googleServerClientId,
      );
      _googleInitialized = true;
    }
    try {
      final account = await google.authenticate();
      final credential = GoogleAuthProvider.credential(
        idToken: account.authentication.idToken,
      );
      await _auth.signInWithCredential(credential);
      return true;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      rethrow;
    }
  }

  Future<void> signOut() async {
    if (!kIsWeb && _googleInitialized) await GoogleSignIn.instance.signOut();
    await _auth.signOut();
  }
}
