// Creates the mongot sync user. searchCoordinator is a BUILT-IN role from
// MongoDB 8.2+ (before that the operator created it as a custom role).
const admin = db.getSiblingDB("admin");
const name = process.env.SEARCH_USER;
try {
  admin.createUser({
    user: name,
    pwd: process.env.SEARCH_PASSWORD,
    roles: [{ role: "searchCoordinator", db: "admin" }],
  });
  print(`created user ${name} with searchCoordinator`);
} catch (e) {
  if (e.code === 51003 || /already exists/i.test(e.message)) { print(`user ${name} already exists`); }
  else { throw e; }
}
