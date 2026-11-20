allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// cronet_http's consumer rule keeps every class under org.chromium.net, which
// holds back about a fifth of the app's methods from R8 for classes that
// nothing calls. app/proguard-rules.pro keeps the Cronet API the bindings and
// the Play services module actually use, so the plugin's rule is emptied here.
// If this hook ever stops matching, the plugin's broader rule applies instead:
// the release build gets bigger, not broken.
subprojects {
    if (name == "cronet_http") {
        tasks.configureEach {
            if (name == "exportReleaseConsumerProguardFiles") {
                doLast {
                    outputs.files.asFileTree
                        .matching { include("**/*.txt", "**/*.pro") }
                        .forEach {
                            it.writeText(
                                "# cronet_http's keep rules are replaced by " +
                                    "android/app/proguard-rules.pro\n",
                            )
                        }
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
