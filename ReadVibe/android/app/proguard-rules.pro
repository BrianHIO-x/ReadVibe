# Project-specific R8 rules.
#
# The current app has no custom Java/Kotlin APIs that need reflection keep
# rules. Flutter and AndroidX/plugin keep rules are supplied by their own
# artifacts; this file exists so release builds can enable code/resource
# shrinking without relying on an implicit path.
