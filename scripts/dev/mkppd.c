#include <cups/cups.h>
#include <stdio.h>
extern const char *_ppdCreateFromIPP(char *buffer, size_t bufsize, ipp_t *supported);
int main(int argc, char **argv) {
  http_t *http = httpConnect2("127.0.0.1", atoi(argv[1]), NULL, AF_UNSPEC, HTTP_ENCRYPTION_NEVER, 1, 5000, NULL);
  if (!http) { fprintf(stderr, "connect failed\n"); return 1; }
  ipp_t *req = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES);
  char uri[256]; snprintf(uri, sizeof uri, "ipp://127.0.0.1:%s/ipp/print", argv[1]);
  ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
  ipp_t *resp = cupsDoRequest(http, req, "/ipp/print");
  if (!resp || cupsLastError() > IPP_STATUS_OK_EVENTS_COMPLETE) { fprintf(stderr, "ipp error: %s\n", cupsLastErrorString()); return 1; }
  char buf[1024];
  const char *f = _ppdCreateFromIPP(buf, sizeof buf, resp);
  if (!f) { fprintf(stderr, "ppd create failed: %s\n", buf); return 1; }
  printf("%s\n", f);
  return 0;
}
