plugins {
    java
    `java-library`
    `maven-publish`
    signing
    id("com.diffplug.spotless") version "8.7.0"
}

group = "io.twilic"
version = "3.0.0"

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
    withJavadocJar()
    withSourcesJar()
}

repositories {
    mavenCentral()
}

dependencies {
    testImplementation(platform("org.junit:junit-bom:5.11.4"))
    testImplementation("org.junit.jupiter:junit-jupiter")
}

tasks.test {
    useJUnitPlatform()
}

tasks.register<JavaExec>("emitRustClientFixtures") {
    group = "interop"
    description = "Emit Rust client interop fixture frames"
    classpath = sourceSets["main"].runtimeClasspath
    mainClass.set("io.twilic.EmitRustClientFixtures")
}

tasks.register<JavaExec>("decodeRustServerFixtures") {
    group = "interop"
    description = "Decode Rust server interop fixture frames from stdin"
    classpath = sourceSets["main"].runtimeClasspath
    mainClass.set("io.twilic.DecodeRustServerFixtures")
    standardInput = System.`in`
}

spotless {
    java {
        target("src/main/java/**/*.java", "src/test/java/**/*.java")
        googleJavaFormat("1.25.2")
        removeUnusedImports()
        trimTrailingWhitespace()
        endWithNewline()
    }
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            from(components["java"])
            pom {
                name.set("twilic")
                description.set(
                    "Java implementation of a fast, compact binary wire format for modern data transport.",
                )
                url.set("https://github.com/twilic/twilic-java")
                licenses {
                    license {
                        name.set("MIT License")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                }
                developers {
                    developer {
                        name.set("Twilic")
                        email.set("maintained-by-minagishl@users.noreply.github.com")
                    }
                }
                scm {
                    connection.set("scm:git:git://github.com/twilic/twilic-java.git")
                    developerConnection.set("scm:git:ssh://github.com:twilic/twilic-java.git")
                    url.set("https://github.com/twilic/twilic-java")
                }
            }
        }
    }
}

signing {
    val signingKey = providers.environmentVariable("ORG_GRADLE_PROJECT_signingKey")
    val signingPassword = providers.environmentVariable("ORG_GRADLE_PROJECT_signingPassword")
    if (signingKey.isPresent && signingPassword.isPresent) {
        useInMemoryPgpKeys(signingKey.get(), signingPassword.get())
        sign(publishing.publications["maven"])
    }
}
