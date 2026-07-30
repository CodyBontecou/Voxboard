const DESTINATION_HOST = "vox.isolated.tech";

export default {
  fetch(request: Request): Response {
    const destination = new URL(request.url);
    destination.protocol = "https:";
    destination.hostname = DESTINATION_HOST;
    destination.port = "";

    return Response.redirect(destination.toString(), 308);
  },
};
