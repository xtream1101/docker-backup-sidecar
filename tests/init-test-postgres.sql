-- Initialize test database with sample data

-- Create sample tables
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(100) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE posts (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    title VARCHAR(200) NOT NULL,
    content TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert sample data
INSERT INTO users (username, email) VALUES
    ('alice', 'alice@example.com'),
    ('bob', 'bob@example.com'),
    ('charlie', 'charlie@example.com');

INSERT INTO posts (user_id, title, content) VALUES
    (1, 'First Post', 'This is Alice''s first post with some sample content.'),
    (1, 'Second Post', 'Another post by Alice about testing backups.'),
    (2, 'Bob''s Introduction', 'Hello, I''m Bob and this is my first post.'),
    (3, 'Charlie''s Thoughts', 'Some thoughts about database backups and recovery.');

-- Display counts
SELECT 'Sample data inserted successfully!' as status;
SELECT COUNT(*) || ' users created' as info FROM users;
SELECT COUNT(*) || ' posts created' as info FROM posts;
