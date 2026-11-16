import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.bizdala.letflow"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.bizdala.letflow"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Pinned to 26 (architecture.md §2: Android API 26+) rather than the
        // Flutter template default — REQ-419.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // flutter_appauth's AndroidManifest.xml declares a redirect-handling
        // intent filter with a `${appAuthRedirectScheme}` placeholder; it
        // must resolve to the app's own custom scheme
        // (com.bizdala.letflow:/oauth2redirect, per REQ-418's Keycloak
        // client registration) or the manifest merge fails. No auth logic
        // is added here — this is app-identity wiring only (REQ-419);
        // REQ-421 implements the actual OIDC flow.
        manifestPlaceholders["appAuthRedirectScheme"] = "com.bizdala.letflow"

        // Platform-host manifest placeholder for the deep-link intent
        // filter (REQ-421 design §1.3/§1.4, OQ-5). Fed from a Gradle
        // property (`-Pplatform-host=<value>`) passed alongside the same
        // build invocation's `--dart-define=LETFLOW_PLATFORM_HOST=<value>`
        // -- Gradle and Dart's build-time-environment constants are two
        // separate mechanisms, so one canonical value is threaded through
        // both rather than inventing a second define name. Empty string is
        // a safe default for a plain `flutter build`/`flutter run` that
        // doesn't pass the property (no host means the intent filter's
        // `*.` host pattern matches no real host, same fail-closed shape as
        // the Dart-side `LETFLOW_PLATFORM_HOST` empty-string default in
        // `parseTenantSlugFromDeepLink`).
        val platformHost = (project.findProperty("platform-host") as String?) ?: ""
        manifestPlaceholders["platformHost"] = platformHost
    }

    // REQ-868: the release build is signed with the upload key described in
    // android/key.properties (git-ignored; keys storeFile, storePassword, keyAlias,
    // keyPassword). There is no fallback to the debug key.
    val keystoreFile = rootProject.file("key.properties")
    val keystoreProps = Properties()
    if (keystoreFile.exists()) {
        keystoreFile.inputStream().use { keystoreProps.load(it) }
    }
    val releaseRequested = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
    if (releaseRequested && !keystoreFile.exists()) {
        throw GradleException(
            "Release build needs android/key.properties (storeFile, storePassword, keyAlias, keyPassword); " +
                "see docs/runbooks/mobile-android-release.md",
        )
    }

    signingConfigs {
        create("release") {
            keystoreProps.getProperty("storeFile")?.let { storeFile = file(it) }
            storePassword = keystoreProps.getProperty("storePassword")
            keyAlias = keystoreProps.getProperty("keyAlias")
            keyPassword = keystoreProps.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}
