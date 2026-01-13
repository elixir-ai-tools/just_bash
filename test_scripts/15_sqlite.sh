#!/bin/bash
# Test: sqlite3
# NOTE: Each test uses a unique database name to avoid state conflicts

# Create table
echo "1: create table"
sqlite3 db1 "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)"
echo "  created"

# Insert data
echo "2: insert"
sqlite3 db1 "INSERT INTO users VALUES (1, 'alice', 'alice@example.com')"
sqlite3 db1 "INSERT INTO users VALUES (2, 'bob', 'bob@example.com')"
sqlite3 db1 "INSERT INTO users VALUES (3, 'charlie', 'charlie@example.com')"
echo "  inserted 3 rows"

# Basic select
echo "3: select all"
sqlite3 db1 "SELECT * FROM users" | wc -l | tr -d ' '

echo "4: select columns"
sqlite3 db1 "SELECT name FROM users" | head -1

echo "5: select with where"
sqlite3 db1 "SELECT name FROM users WHERE id > 1" | head -1

echo "6: select with order"
sqlite3 db1 "SELECT name FROM users ORDER BY name" | head -1

echo "7: select with limit"
sqlite3 db1 "SELECT name FROM users LIMIT 2" | wc -l | tr -d ' '

# Aggregates
echo "8: count"
sqlite3 db1 "SELECT COUNT(*) FROM users"

# Update
echo "9: update"
sqlite3 db1 "UPDATE users SET name = 'alicia' WHERE id = 1"
sqlite3 db1 "SELECT name FROM users WHERE id = 1"

# Delete
echo "10: delete"
sqlite3 db1 "DELETE FROM users WHERE id = 3"
sqlite3 db1 "SELECT COUNT(*) FROM users"

# Multiple tables in new db
echo "11: create orders"
sqlite3 db2 "CREATE TABLE users (id INTEGER, name TEXT)"
sqlite3 db2 "CREATE TABLE orders (id INTEGER, user_id INTEGER, amount INTEGER)"
sqlite3 db2 "INSERT INTO users VALUES (1, 'alice')"
sqlite3 db2 "INSERT INTO users VALUES (2, 'bob')"
sqlite3 db2 "INSERT INTO orders VALUES (1, 1, 100)"
sqlite3 db2 "INSERT INTO orders VALUES (2, 1, 150)"
sqlite3 db2 "INSERT INTO orders VALUES (3, 2, 50)"
echo "  created"

# Join
echo "12: join"
sqlite3 db2 "SELECT users.name, orders.amount FROM users JOIN orders ON users.id = orders.user_id" | wc -l | tr -d ' '

# Group by
echo "13: group by"
sqlite3 db2 "SELECT user_id, COUNT(*) FROM orders GROUP BY user_id" | wc -l | tr -d ' '

# Expressions
echo "14: expressions"
sqlite3 db2 "SELECT 1 + 2"

echo "15: like"
sqlite3 db2 "SELECT name FROM users WHERE name LIKE 'a%'"

echo "16: done"
