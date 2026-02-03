buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:3.5.3")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        val nativeDir = if (System.getProperty("os.name").toLowerCase().contains("windows")) {
            System.getenv("CORONA_ROOT")
        } else {
            "${System.getenv("HOME")}/Library/Application Support/Corona/Native/"
        }
        flatDir {
            dirs("$nativeDir/Corona/android/lib/gradle", "$nativeDir/Corona/android/lib/Corona/libs")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.buildDir)
}
