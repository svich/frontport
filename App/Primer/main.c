// frontport-primer: exits at once. Frontport wraps it in a stand-in app with a Port's bundle ID and runs it in the
// sandbox, so macOS recreates the Port's Data folder (after Delete Data) without running any Port code.
int main(void) { return 0; }
