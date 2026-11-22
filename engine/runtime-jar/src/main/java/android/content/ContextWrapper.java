package android.content;

import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.res.AssetManager;
import android.content.res.Resources;
import android.os.Bundle;
import android.os.Looper;
import java.io.File;

public class ContextWrapper extends Context {
    private Context base;

    public ContextWrapper(Context base) {
        this.base = base;
    }

    protected void attachBaseContext(Context base) {
        if (this.base != null) throw new IllegalStateException("Base context already set");
        this.base = base;
    }

    @Override public Context getBaseContext() { return base; }
    @Override public Context getApplicationContext() { return base.getApplicationContext(); }
    @Override public ClassLoader getClassLoader() { return base.getClassLoader(); }
    @Override public void setClassLoader(ClassLoader loader) { base.setClassLoader(loader); }
    @Override public String getPackageName() { return base.getPackageName(); }
    @Override public String getOpPackageName() { return base.getOpPackageName(); }

    @Override public File getFilesDir() { return base.getFilesDir(); }
    @Override public File getCacheDir() { return base.getCacheDir(); }
    @Override public File getNoBackupFilesDir() { return base.getNoBackupFilesDir(); }
    @Override public File getCodeCacheDir() { return base.getCodeCacheDir(); }
    @Override public File getExternalFilesDir(String type) { return base.getExternalFilesDir(type); }
    @Override public File getExternalCacheDir() { return base.getExternalCacheDir(); }
    @Override public File getDir(String name, int mode) { return base.getDir(name, mode); }
    @Override public File getDatabasePath(String name) { return base.getDatabasePath(name); }
    @Override public File getObbDir() { return base.getObbDir(); }

    @Override public Resources getResources() { return base.getResources(); }
    @Override public AssetManager getAssets() { return base.getAssets(); }
    @Override public PackageManager getPackageManager() { return base.getPackageManager(); }
    @Override public ApplicationInfo getApplicationInfo() { return base.getApplicationInfo(); }
    @Override public PackageInfo getPackageInfo(String name, int flags) { return base.getPackageInfo(name, flags); }
    @Override public String getString(int id) { return base.getString(id); }
    @Override public String getString(int id, Object... args) { return base.getString(id, args); }
    @Override public CharSequence getText(int id) { return base.getText(id); }

    @Override public int checkCallingOrSelfPermission(String permission) { return base.checkCallingOrSelfPermission(permission); }
    @Override public int checkPermission(String permission, int pid, int uid) { return base.checkPermission(permission, pid, uid); }
    @Override public int checkSelfPermission(String permission) { return base.checkSelfPermission(permission); }
    @Override public Object getSystemService(String name) { return base.getSystemService(name); }
    @Override public String getSystemServiceName(Class<?> type) { return base.getSystemServiceName(type); }
    @Override public SharedPreferences getSharedPreferences(String name, int mode) { return base.getSharedPreferences(name, mode); }
    @Override public ContentResolver getContentResolver() { return base.getContentResolver(); }
    @Override public Looper getMainLooper() { return base.getMainLooper(); }

    @Override public void startActivity(Intent intent) { base.startActivity(intent); }
    @Override public void startActivity(Intent intent, Bundle options) { base.startActivity(intent, options); }
    @Override public void startActivities(Intent[] intents) { base.startActivities(intents); }
    @Override public void startService(Intent service) { base.startService(service); }
    @Override public boolean stopService(Intent service) { return base.stopService(service); }
    @Override public boolean bindService(Intent service, ServiceConnection connection, int flags) { return base.bindService(service, connection, flags); }
    @Override public void unbindService(ServiceConnection connection) { base.unbindService(connection); }
    @Override public void sendBroadcast(Intent intent) { base.sendBroadcast(intent); }
    @Override public void sendBroadcast(Intent intent, String permission) { base.sendBroadcast(intent, permission); }
    @Override public void sendOrderedBroadcast(Intent intent, String permission) { base.sendOrderedBroadcast(intent, permission); }
    @Override public Intent registerReceiver(Object receiver, IntentFilter filter) { return base.registerReceiver(receiver, filter); }
    @Override public void unregisterReceiver(Object receiver) { base.unregisterReceiver(receiver); }
    @Override public boolean isRestricted() { return base.isRestricted(); }
    @Override public void enforceCallingOrSelfPermission(String permission, String message) { base.enforceCallingOrSelfPermission(permission, message); }
}
