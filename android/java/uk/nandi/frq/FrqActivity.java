package uk.nandi.frq;

import android.app.NativeActivity;
import android.content.ContentResolver;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Build;
import android.provider.MediaStore;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * The only Java in the app, and it exists for one reason: a picture chooser
 * answers through {@code onActivityResult}, and a plain NativeActivity has
 * nowhere to deliver that. Everything else the app does — the window, the
 * event loop, the UI — is native, and this class does not touch any of it.
 *
 * The native side reaches the methods below over JNI, by name, on the
 * activity handle the glue already holds. See vidya's `vidya_pick_image` and
 * `vidya_picked_image`.
 *
 * The other reason it exists is the runtime permission dialog: the manifest
 * can only declare CAMERA and RECORD_AUDIO, and asking for them is an
 * Activity call. {@link CameraCapture} asks through here rather than failing
 * at a permission it could have had for the asking.
 */
public class FrqActivity extends NativeActivity {
    private static final String TAG = "VidyaJolt";
    private static final int PICK_IMAGE = 0x1CE;
    private static final int PERMISSIONS = 0x1CF;

    /**
     * What a call needs and cannot be given by the manifest: both are runtime
     * permissions, so the manifest only makes them askable and this activity
     * is what asks. The picture chooser is deliberately not here — the picker
     * hands back a grant for the one file that was chosen, so it needs no
     * standing permission at all.
     */
    private static final String[] CALL_PERMISSIONS = {
        android.Manifest.permission.CAMERA,
        android.Manifest.permission.RECORD_AUDIO,
    };

    /** Where the last pick was written, until the native side takes it. */
    private volatile String picked;

    /** What to run when the dialog is answered, whichever way it is answered. */
    private volatile Runnable afterPermissions;

    /**
     * Asked for at startup rather than at the first call, because the call is
     * not where they can be asked from: the microphone is opened by cpal
     * inside the media plane, which is Rust with no Activity to raise a dialog
     * on, and by the time it fails the call is already up. A denied mic there
     * is not a prompt but a dead pipeline — the audio stream never builds, and
     * a second later the pipeline gives up reading a source that was never
     * there.
     *
     * So both are asked for once, here, before anything can want them. The
     * answer is not waited for: the dialog is its own window and the activity
     * carries on behind it, exactly as it would if the permissions were
     * already held.
     */
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        ensurePermissions(CALL_PERMISSIONS, null);
    }

    /**
     * Open the system photo picker. Called from the UI thread or off it, so it
     * hops to the right one itself.
     *
     * ACTION_PICK_IMAGES where there is one (API 33+): it shows the reader's
     * own photos without this app holding any storage permission at all, since
     * what comes back is a grant for the one picture they chose. Below that,
     * the document picker does the same job through the same result.
     *
     * PNG only, because PNG is what the tree backend paints and what the
     * upload sends — a chooser offering pictures the app then refuses would be
     * a worse answer than one that never offered them.
     */
    public void pickImage() {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                Intent intent;
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent = new Intent(MediaStore.ACTION_PICK_IMAGES);
                } else {
                    intent = new Intent(Intent.ACTION_GET_CONTENT);
                    intent.addCategory(Intent.CATEGORY_OPENABLE);
                }
                intent.setType("image/png");
                try {
                    startActivityForResult(intent, PICK_IMAGE);
                } catch (Exception e) {
                    Log.e(TAG, "no picture chooser on this device", e);
                }
            }
        });
    }

    /**
     * The picture chosen since the last call, as a path, or null.
     *
     * Handed over once: a caller polling for it must not attach the same
     * picture twice, and the file is the native side's to move from here.
     */
    public String takePickedImage() {
        String path = picked;
        picked = null;
        return path;
    }

    /**
     * Ask for the camera and the microphone, and say nothing about the answer.
     *
     * Here for the native side, which reaches it over JNI by name the same way
     * it reaches {@link #pickImage} — a call that is about to open the mic can
     * raise the dialog before it does. Granting is not waited for: the dialog
     * is a separate window and the caller carries on without it.
     */
    public void requestCallPermissions() {
        ensurePermissions(CALL_PERMISSIONS, null);
    }

    /**
     * Ask for whichever of {@code perms} is not held yet, then run {@code after}
     * on the UI thread — after the reader answers, or immediately if there was
     * nothing to ask. {@code after} is told nothing: what it does next is a
     * fresh {@code checkSelfPermission}, because a dialog can be dismissed and
     * a permission can be revoked from Settings while the app is running.
     *
     * One dialog at a time. A second ask while the first is still up would
     * lose the first one's callback, so it is refused and answers late — when
     * the outstanding one comes back.
     */
    public void ensurePermissions(final String[] perms, final Runnable after) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                List<String> missing = new ArrayList<>();
                for (String p : perms) {
                    if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) {
                        missing.add(p);
                    }
                }
                if (missing.isEmpty() || afterPermissions != null) {
                    if (!missing.isEmpty()) {
                        Log.w(TAG, "a permission dialog is already up; not asking again");
                    }
                    if (after != null) {
                        after.run();
                    }
                    return;
                }
                afterPermissions = after;
                requestPermissions(missing.toArray(new String[0]), PERMISSIONS);
            }
        });
    }

    @Override
    public void onRequestPermissionsResult(int request, String[] perms, int[] results) {
        super.onRequestPermissionsResult(request, perms, results);
        if (request != PERMISSIONS) {
            return;
        }
        Runnable after = afterPermissions;
        afterPermissions = null;
        if (after != null) {
            after.run();
        }
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != PICK_IMAGE) {
            return;
        }
        Uri uri = result == RESULT_OK && data != null ? data.getData() : null;
        if (uri == null) {
            // Cancelled, or a chooser that answered with nothing. Not an
            // error: the picker screen is still there to try again from.
            return;
        }
        // Copied out now, while the grant on that URI is still live — it is
        // this activity's for the length of the result and no longer.
        File out = new File(getCacheDir(), "picked-" + System.nanoTime() + ".png");
        ContentResolver resolver = getContentResolver();
        try (InputStream in = resolver.openInputStream(uri);
             OutputStream os = new FileOutputStream(out)) {
            if (in == null) {
                throw new java.io.IOException("nothing to read at " + uri);
            }
            byte[] buf = new byte[1 << 16];
            for (int n = in.read(buf); n > 0; n = in.read(buf)) {
                os.write(buf, 0, n);
            }
        } catch (Exception e) {
            Log.e(TAG, "could not read the chosen picture", e);
            out.delete();
            return;
        }
        picked = out.getAbsolutePath();
    }
}
