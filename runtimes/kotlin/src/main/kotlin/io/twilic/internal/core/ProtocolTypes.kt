package io.twilic.internal.core

class SessionOptions {
    @JvmField var maxBaseSnapshots: Int = 8
    @JvmField var enableStatePatch: Boolean = true
    @JvmField var enableTemplateBatch: Boolean = true
    @JvmField var enableTrainedDictionary: Boolean = true
    @JvmField var unknownReferencePolicy: UnknownReferencePolicy = UnknownReferencePolicy.FAIL_FAST
}

enum class UnknownReferencePolicy {
    FAIL_FAST,
    STATELESS_RETRY,
}
