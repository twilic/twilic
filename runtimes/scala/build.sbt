ThisBuild / organization := "io.twilic"
ThisBuild / version := "3.0.0"
ThisBuild / scalaVersion := "3.3.4"
ThisBuild / scalacOptions ++= Seq("-deprecation", "-feature")

lazy val root = (project in file("."))
  .settings(
    name := "twilic",
    libraryDependencies ++= Seq(
      "org.scalatest" %% "scalatest" % "3.2.19" % Test,
      "org.junit.jupiter" % "junit-jupiter" % "5.11.4" % Test,
      "org.junit.platform" % "junit-platform-launcher" % "1.11.4" % Test,
    ),
    Test / parallelExecution := false,
    Test / testOptions += Tests.Argument("-oDF"),
    Test / testFrameworks := Seq(TestFrameworks.ScalaTest, TestFrameworks.JUnit),
    Compile / compileOrder := CompileOrder.Mixed,
    Compile / javaSource := baseDirectory.value / "src/main/java",
    Test / javaSource := baseDirectory.value / "src/test/java",
    Compile / run / mainClass := Some("io.twilic.EmitRustClientFixtures"),
  )

lazy val emitRustClientFixtures = taskKey[Unit]("Emit Rust client interop fixture frames")

emitRustClientFixtures := {
  (Compile / runMain).toTask(" io.twilic.EmitRustClientFixtures").value
}

lazy val decodeRustServerFixtures = taskKey[Unit]("Decode Rust server interop fixture frames from stdin")

decodeRustServerFixtures := {
  (Compile / runMain).toTask(" io.twilic.DecodeRustServerFixtures").value
}
