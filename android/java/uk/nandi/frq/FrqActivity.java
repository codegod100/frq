package uk.nandi.frq;

import android.app.NativeActivity;
import android.content.ContentResolver;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * The only Java in the app, and it exists for one reason: a picture chooser
 * answers through {@code onActivityResult}, and a plain NativeActivity has
 * nowhere to deliver that. Everything else the app does — the window, the
 * event loop, the UI — is native, and this class does not touch any of it.
 *
 * The native side reaches the two methods below over JNI, by name, on the
 * activity handle the glue already holds. See vidya's `vidya_pick_image` and
 * `vidya_picked_image`.
 */
public class FrqActivity extends NativeActivity {
    private static final String TAG = "VidyaJolt";
    private static final int PICK_IMAGE = 0x1CE;

    /** Where the last pick was written, until the native side takes it. */
    private volatile String picked;

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
