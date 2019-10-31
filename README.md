# Transparent Classroom API Scripts

This is a collection of several API scripts using the Transparent Classroom API.

The scripts are meant to serve as examples of what is possible.

The documentation for the API is at http://transparentclassroom.com/api

## Setup

Follow these instructions to run a script using ruby.

1. Follow the instructions on http://transparentclassroom.com/api to get your API token. Then set it as an environment variable.

    ```export TC_API_TOKEN=my_api_token```

1. Optionally, set a masquerade_id:

    ```export TC_MASQUERADE_ID=masquerade_id```

1. Install gems ```bundle install```

1. Script specific setup

    1. `pull_retention_rates.rb`

        * Define optional `config.yml` (refer to `config.template.yml`)

    1. `pull_all_children.rb`

        * Set the `SCHOOL_YEAR` env var for the year of data you would like to pull, use the format `YYYY-YY`:

            ```export SCHOOL_YEAR=2018-19```

1. Run a script ```ruby ./pull_retention_rates.rb```

