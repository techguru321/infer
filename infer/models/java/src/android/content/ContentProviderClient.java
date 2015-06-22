/*
* Copyright (c) 2013- Facebook.
* All rights reserved.
*/

package android.content;

import com.facebook.infer.models.InferBuiltins;
import com.facebook.infer.models.InferUndefined;

import android.database.Cursor;
import android.database.sqlite.SQLiteCursor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.RemoteException;


public class ContentProviderClient {

    private ContentResolver mContentResolver;
    private IContentProvider mContentProvider;
    private String mPackageName;
    private boolean mStable;

    ContentProviderClient(
            ContentResolver contentResolver, IContentProvider contentProvider, boolean stable) {
        mContentResolver = contentResolver;
        mContentProvider = contentProvider;
        mPackageName = InferUndefined.string_undefined();
        mStable = stable;
    }

    public Cursor query(Uri url, String[] projection, String selection,
                        String[] selectionArgs, String sortOrder) throws RemoteException {
        return query(url, projection, selection, selectionArgs, sortOrder, null);
    }

    public Cursor query(Uri url, String[] projection, String selection, String[] selectionArgs,
                        String sortOrder, CancellationSignal cancellationSignal) throws RemoteException {
        return new SQLiteCursor(null, null, null);
    }

    private class NotRespondingRunnable {
    }


}
