/*
 * Copyright (c) 2018 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

import java.util.concurrent.TimeUnit;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeoutException;
import android.support.annotation.UiThread;
import android.os.AsyncTask;

class AsyncTaskGet {
  CountTask task;
  Object lock;

  @UiThread
  void taskGetOnUiThreadBad() throws InterruptedException, ExecutionException {
    task.get();
  }

  @UiThread
  void taskGetWithTimeoutOnUiThreadOk()
    throws TimeoutException, InterruptedException, ExecutionException {
    task.get(1000, TimeUnit.NANOSECONDS);
  }

  @UiThread
  void lockOnUiThreadBad() {
    synchronized(lock) {}
  }

  void taskGetUnderLock() throws InterruptedException, ExecutionException {
    synchronized(lock) {
      task.get();
    }
  }

  void taskGetonBGThreadOk() throws InterruptedException, ExecutionException {
    task.get();
  }
}

class CountTask extends AsyncTask<Integer, Void, Long> {
   protected Long doInBackground(Integer... ints) {
     long totalSize = 0;
     for (int i = 0; i < ints.length; i++) {
       totalSize += ints[i];
       if (isCancelled()) break;
     }
     return totalSize;
   }
 }
