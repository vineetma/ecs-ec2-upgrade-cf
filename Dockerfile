FROM node:18-alpine
WORKDIR /app
COPY src/ .
EXPOSE 3000
CMD ["node", "app.js"]
