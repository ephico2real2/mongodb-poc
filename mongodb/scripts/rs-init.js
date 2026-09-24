// Initiate the replica set and create users. Run once, via the localhost
// exception, from inside mongo1. Idempotent-ish: skips initiate if already set.
const RS   = process.env.REPLSET;
const HOST = process.env.ADVERTISED_HOST;
const P1 = parseInt(process.env.PORT1), P2 = parseInt(process.env.PORT2), P3 = parseInt(process.env.PORT3);

let already = false;
try { rs.status(); already = true; } catch (e) { already = false; }

if (!already) {
  print(`initiating ${RS} with ${HOST}:${P1},${P2},${P3}`);
  rs.initiate({
    _id: RS,
    members: [
      { _id: 0, host: `${HOST}:${P1}`, priority: 2 },
      { _id: 1, host: `${HOST}:${P2}` },
      { _id: 2, host: `${HOST}:${P3}` },
    ],
  });
} else {
  print("replica set already initiated");
}

// Wait for this node to become PRIMARY before any user creation.
let primary = false;
for (let i = 0; i < 60; i++) {
  try { if (db.hello().isWritablePrimary) { primary = true; break; } } catch (e) {}
  sleep(2000);
}
if (!primary) { throw new Error("no PRIMARY after 120s"); }
print("PRIMARY is up");

const admin = db.getSiblingDB("admin");

// Under the localhost exception we may CREATE the first user but may NOT run
// usersInfo/getUser -- that command is itself unauthorized. So attempt the
// create and treat "already exists" (code 51003) as success.
function ensureUser(name, pwd, roles) {
  try {
    admin.createUser({ user: name, pwd: pwd, roles: roles });
    print(`created user ${name}`);
  } catch (e) {
    if (e.code === 51003 || /already exists/i.test(e.message)) {
      print(`user ${name} already exists`);
    } else {
      throw e;
    }
  }
}

ensureUser(process.env.ROOT_USER, process.env.ROOT_PASSWORD, [{ role: "root", db: "admin" }]);
