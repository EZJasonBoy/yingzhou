#include <jni.h>

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    return JNI_VERSION_1_6;
}

JNIEXPORT jint JNICALL Java_tvbox_fixture_NativeMath_add(JNIEnv *env, jclass type, jint left, jint right) {
    return (jint)((unsigned int)left + (unsigned int)right);
}
