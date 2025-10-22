// Initialize MongoDB test database with sample data

// Switch to test database
db = db.getSiblingDB('testdb');

// Create users collection with sample data
db.users.insertMany([
    {
        username: 'alice',
        email: 'alice@example.com',
        role: 'admin',
        createdAt: new Date(),
        profile: {
            firstName: 'Alice',
            lastName: 'Anderson',
            age: 30
        }
    },
    {
        username: 'bob',
        email: 'bob@example.com',
        role: 'user',
        createdAt: new Date(),
        profile: {
            firstName: 'Bob',
            lastName: 'Builder',
            age: 25
        }
    },
    {
        username: 'charlie',
        email: 'charlie@example.com',
        role: 'user',
        createdAt: new Date(),
        profile: {
            firstName: 'Charlie',
            lastName: 'Chen',
            age: 28
        }
    }
]);

// Create posts collection with sample data
db.posts.insertMany([
    {
        title: 'First MongoDB Post',
        content: 'This is Alice\'s first post about MongoDB backups.',
        author: 'alice',
        tags: ['mongodb', 'backup', 'testing'],
        createdAt: new Date(),
        likes: 5
    },
    {
        title: 'MongoDB Best Practices',
        content: 'Some thoughts on database backups and recovery.',
        author: 'alice',
        tags: ['mongodb', 'best-practices'],
        createdAt: new Date(),
        likes: 12
    },
    {
        title: 'Hello from Bob',
        content: 'My first post in this system.',
        author: 'bob',
        tags: ['introduction'],
        createdAt: new Date(),
        likes: 3
    },
    {
        title: 'Data Modeling Tips',
        content: 'Charlie\'s guide to effective data modeling.',
        author: 'charlie',
        tags: ['mongodb', 'data-modeling'],
        createdAt: new Date(),
        likes: 8
    }
]);

// Create indexes
db.users.createIndex({ username: 1 }, { unique: true });
db.users.createIndex({ email: 1 }, { unique: true });
db.posts.createIndex({ author: 1 });
db.posts.createIndex({ tags: 1 });
db.posts.createIndex({ createdAt: -1 });

// Display summary
print('MongoDB test database initialized successfully!');
print('Users created: ' + db.users.countDocuments());
print('Posts created: ' + db.posts.countDocuments());
print('Indexes created on both collections');
