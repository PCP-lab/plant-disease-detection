# Firebase

1. Create a Firebase project and put its ID in `.firebaserc`.
2. Enable **Authentication** (Email/Password + Google), **Cloud Firestore** and **Cloud Storage**.
3. Deploy the rules from this folder:
   ```bash
   npm i -g firebase-tools
   firebase login
   firebase deploy --only firestore:rules,firestore:indexes,storage
   ```

## Data layout
- Firestore: `users/{uid}/scans/{scanId}` → `created_at, image_path, overlay_path, status, primary, leaves, model_version`
- Storage: `scans/{uid}/{scanId}/original.jpg`, `scans/{uid}/{scanId}/overlay.png`

Only the backend writes, using the Admin SDK (which bypasses rules). Users can read and delete only their own scans.
