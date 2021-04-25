import std.conv;
import std.path;
import std.regex;
import std.range;
import std.array;
import std.string;
import std.algorithm;
import std.exception;

import vibe.d;
import vibe.rcon;

const CONFIG_FILE = "config/application.json";
const READ_TIMEOUT = 2.dur!"seconds";

const Json settings;

shared static this() {
    // Load configs
    auto json = cast(string)readFile(CONFIG_FILE);
    settings = parseJson(json, null, CONFIG_FILE);
}

void main() {
    // Setup Server
    auto serverSettings = new HTTPServerSettings;
    serverSettings.port = settings["port"].to!ushort;

    auto bindAddresses = settings["bind-addresses"].get!(Json[]).map!(j => j.to!string);
    serverSettings.bindAddresses = cast(string[])bindAddresses.array;

    // Setup Logging
    auto logsDir = settings["logs-dir"].to!string;
    // Log access to the log file
    serverSettings.accessLogFile = buildPath(logsDir, "verify-roster-access.log");

    // Log to the proper log file
    auto fileLogger = cast(shared)new FileLogger(buildPath(logsDir, "verify-roster.log"));
    fileLogger.minLevel = LogLevel.info;
    registerLogger(fileLogger);

    // Better log formatting
    setLogFormat(FileLogger.Format.thread, FileLogger.Format.thread);

    // Setup Routes
    auto router = new URLRouter;
    router.get("/", &index);
    router.post("/check", &check);
    router.get("/favicon.ico", serveStaticFile("public/favicon.ico"));

    listenHTTP(serverSettings, router);

    runApplication();
}

struct APIMatch {
    ulong id;
    APILeague league;
    APIRoster home_team;
    APIRoster away_team;
    @ignore SourcePlayer[] extraSourcePlayers;
}

struct APILeague {
    string name;
}

struct APIRoster {
    ulong id;
    ulong team_id;
    string name;
    APIUser[] players;
}

struct APIUser {
    ulong id;
    string name;
    string profile_url;
    string steam_32;
    long steam_64;
    string steam_id3;
    @ignore SourcePlayer sourcePlayer;
}

struct SourcePlayer {
    string name;
    string steam_id3;
    long steam_64;
    APIUser* user;
}

@property auto endpoint() {
    return settings["api-endpoint"].to!string;
}

void index(HTTPServerRequest req, HTTPServerResponse res) {
    string link;
    if ("link" in req.query) link = req.query["link"];

    res.render!("index.dt", link);
}

void check(HTTPServerRequest req, HTTPServerResponse res) {
    // Validate form data
    if ("match" !in req.form) return res.renderError("Missing Match Link");
    if ("string" !in req.form && "status" !in req.form) return res.renderError("Missing Connect String or Status");

    // Get match link
    auto matchLink = req.form["match"];
    if (matchLink.matchFirst(`^[0-9]+$`)) {
        matchLink = "%s/matches/%s".format(endpoint, matchLink);
    }

    // Validate match link format
    if (!matchLink.matchFirst(`^%s/matches/[0-9]+$`.format(endpoint.escaper))) {
        return res.renderError("Invalid Match Link");
    }
    auto match_id = matchLink.split("/")[$-1].to!int;

    string status;
    if ("string" in req.form && req.form["string"] != "") {
        // Get it through RCON
        try {
            auto connectString = req.form["string"];
            auto client = parseConnectString(connectString);
            status = client.exec("status");
        } catch (Exception e) {
            logError("%s", e);
            res.renderError(e.msg);
            return;
        }
    } else if (req.form["status"] != "") {
        status = req.form["status"];
    } else {
        return res.renderError("Missing Connect String or Status");
    }

    Json json;
    try {
        // Perform API call to get the match
        json = apiGet("/matches/%s".format(match_id));

        if ("match" in json) {
            // Fill in match data
            auto match = json["match"].deserializeJson!APIMatch;
            parseStatus(status, match);
            getOZFortressUsers(match);

            return res.render!("check.dt", endpoint, match);
        }
    } catch(Exception e) {
        logError("%s", e);
    }

    res.renderError("Invalid API response", json.toString);
}

void renderError(HTTPServerResponse res, string message, string info = "") {
    res.render!("error.dt", message, info);
}

auto apiGet(string path) {
    auto url = "%s/api/v1%s".format(endpoint, path);

    auto res = requestHTTP(url, (scope req) {
        req.method = HTTPMethod.GET;
        // Authentication
        req.headers.addField("X-API-Key", settings["api-key"].to!string);
    });

    return res.bodyReader.readAllUTF8().parseJsonString();
}

void parseStatus(string status, ref APIMatch match) {
    foreach (line; status.split("\n")) {
        // Filter out lines not belonging to the user table
        if (line.empty || line[0] != '#') continue;

        // Parse name
        auto nameMatch = line.matchFirst(`".*"`);
        if (nameMatch.empty) continue;
        auto name = nameMatch[0][1..$-1];

        // Parse steam id
        auto steamIdMatch = line.matchFirst(`\[U:1:[0-9]+\]`);
        if (steamIdMatch.empty) continue;
        auto steamId3 = steamIdMatch[0][1..$-1];

        // Calculate steam64
        auto steam64 = 76_561_197_960_265_728 + steamId3.split(":")[2].to!long;

        auto player = SourcePlayer(name, steamId3, steam64);

        // Match player to users in the match
        auto found = false;
        foreach (ref user; chain(match.home_team.players, match.away_team.players)) {
            if (user.steam_id3 == player.steam_id3) {
                user.sourcePlayer = player;
                found = true;
                break;
            }
        }

        // Keep track of players not in the match
        if (!found) {
            match.extraSourcePlayers ~= player;
        }
    }
}

void getOZFortressUsers(APIMatch match) {
    auto tasks = match.extraSourcePlayers.map!((ref player) {
        return runTask({
            try {
                // Fetch user by steam id
                auto json = apiGet("/users/steam_id/%s".format(player.steam_64));

                if ("user" in json) {
                    // map user to player
                    auto user = json["user"].deserializeJson!APIUser;
                    player.user = new APIUser;
                    *player.user = user;
                    return;
                }
            } catch(Exception e) {
                logError("%s", e);
            }
        });
    });

    foreach (task; tasks) {
        task.join();
    }
}

RCONClient parseConnectString(string connectString) {
    auto commands = connectString.split(";");

    string address;
    string password;
    string rconPassword;

    foreach (command; commands) {
        command = command.strip();

        auto value = parseSourceCommandVariale(command, "connect");
        if (value !is null) address = value;

        value = parseSourceCommandVariale(command, "password");
        if (value !is null) password = value;

        value = parseSourceCommandVariale(command, "rcon_password");
        if (value !is null) rconPassword = value;
    }

    enforce(address !is null, "Missing connect in connect string");
    enforce(rconPassword !is null, "Missing rcon_password in connect string");

    auto splits = address.split(":");

    auto connection = connectTCP(splits[0], splits[1].to!ushort);
    connection.readTimeout = READ_TIMEOUT;

    auto client = new RCONClient(connection);
    client.authenticate(rconPassword);
    return client;
}

string parseSourceCommandVariale(string command, string variable) {
    command = command.stripLeft();

    auto start = variable ~ " ";
    if (!command.startsWith(start)) return null;

    auto value = command[start.length..$].strip();

    if (value[0] == '"') value = value[1..$ - 1];

    return value;
}
