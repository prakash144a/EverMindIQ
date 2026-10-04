/// There is no link-opening plugin in the native build, so this reports that it
/// could not, and the caller shows the address to read or copy instead.
bool openLink(String url) => false;
